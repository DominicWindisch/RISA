/*
 * This file is part of the RISA-library.
 *
 * Copyright (C) 2016 Helmholtz-Zentrum Dresden-Rossendorf
 *
 * RISA is free software: You can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * RISA is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with RISA. If not, see <http://www.gnu.org/licenses/>.
 *
 * Date: 30 November 2016
 * Authors: Tobias Frust (FWCC) <t.frust@hzdr.de>
 *
 */

#include "interpolationFunctions.h"

#include <risa/DetectorInterpolation/DetectorInterpolation.h>
#include <risa/ConfigReader/ConfigReader.h>

#include <ddrf/cuda/Coordinates.h>
#include <ddrf/cuda/Check.h>
#include <ddrf/MemoryPool.h>

#include <boost/log/trivial.hpp>

#include <nvToolsExt.h>

#include <exception>
#include <numeric>
#include <algorithm>
#include <iostream>
#include <pthread.h>

namespace risa {
namespace cuda {

DetectorInterpolation::DetectorInterpolation(const std::string& configFile){

   if (readConfig(configFile)) {
      throw std::runtime_error(
            "Configuration file could not be read. Please check!");
   }

   CHECK(cudaGetDeviceCount(&numberOfDevices_));
   for(auto i = 0; i < numberOfDevices_; i++){
      memoryPoolIdxs_[i] = ddrf::MemoryPool<ddrf::cuda::HostMemoryManager<unsigned short, ddrf::cuda::async_copy_policy>>::instance()->registerStage(500, numberOfDetectors_*numberOfProjections_);
      //custom streams are necessary, because profiling with nvprof seems to be
      //not possible with -default-stream per-thread option
      cudaStream_t stream;
      CHECK(cudaStreamCreate(&stream));
      streams_[i] = stream;
   }


   //initialize worker threads
   for (auto i = 0; i < numberOfDevices_; i++) {
      processorThreads_[i] = std::thread { &DetectorInterpolation::processor, this, i };
   }

   BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::DetectorInterpolation: Running " << numberOfDevices_ << " Threads.";
}

DetectorInterpolation::~DetectorInterpolation() {
   for(auto id: defects_){
      BOOST_LOG_TRIVIAL(info) << "Defects: " << id;
   }
}

auto DetectorInterpolation::process(input_type&& sinogram) -> void {
   if (sinogram.valid()) {
      sinograms_[sinogram.device()].push(std::move(sinogram));
   } else {
      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::DetectorInterpolation: Received sentinel, finishing.";

      //send sentinel to all processor threads and wait 'til they're finished
      for(auto i = 0; i < numberOfDevices_; i++){
         sinograms_[i].push(input_type());
      }

      //wait until all threads are finished
      for(auto i = 0; i < numberOfDevices_; i++){
         processorThreads_[i].join();
      }

      //push sentinel to results for next stage
      results_.push(output_type());

      BOOST_LOG_TRIVIAL(info)<< "recoLib::cuda::DetectorInterpolation: Finished.";
   }
}

auto DetectorInterpolation::wait() -> output_type {
   return results_.take();
}

auto DetectorInterpolation::processor(int deviceID) -> void {
   //nvtxNameOsThreadA(pthread_self(), "DetectorInterpolation");
   CHECK(cudaSetDevice(deviceID));
   BOOST_LOG_TRIVIAL(info) << "recoLib::cuda::DetectorInterpolation: Running Thread for Device " << deviceID;
   std::vector<double> filterFunction{0.5, 1.0, 1.0, 1.0, 1.5, 2.0, 3.0, 3.5, 2.0, 3.5, 3.0, 2.0, 1.5, 1.0, 1.0, 1.0, 0.5};
   double sum = std::accumulate(filterFunction.cbegin(), filterFunction.cend(), 0.0);
   std::transform(filterFunction.begin(), filterFunction.end(), filterFunction.begin(),
         std::bind1st(std::multiplies<double>(), 1.0/sum));
   while (true) {
      auto sinogram = sinograms_[deviceID].take();
      if (!sinogram.valid())
         break;

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::DetectorInterpolation: Copy sinogram " << sinogram.index() << " to device " << deviceID;

      auto h_sino = ddrf::MemoryPool<ddrf::cuda::HostMemoryManager<unsigned short, ddrf::cuda::async_copy_policy>>::instance()->requestMemory(memoryPoolIdxs_[deviceID]);

      CHECK(cudaMemcpyAsync(h_sino.container().get(), sinogram.container().get(), sizeof(unsigned short)*numberOfProjections_*numberOfDetectors_, cudaMemcpyDeviceToHost, streams_[deviceID]));

      CHECK(cudaStreamSynchronize(streams_[deviceID]));

      std::vector<int> defectDetectors(numberOfDetectors_, 0);

      findDefectDetectors(h_sino.container().get(), filterFunction, defectDetectors, numberOfDetectors_, numberOfProjections_,
            threshMin_, threshMax_);

      interpolateDefectDetectors(h_sino.container().get(), defectDetectors, numberOfDetectors_, numberOfProjections_);

      CHECK(cudaMemcpyAsync(sinogram.container().get(), h_sino.container().get(),
                   sinogram.size() * sizeof(unsigned short), cudaMemcpyHostToDevice, streams_[deviceID]));
      CHECK(cudaStreamSynchronize(streams_[deviceID]));
      results_.push(std::move(sinogram));

      BOOST_LOG_TRIVIAL(debug)<< "recoLib::cuda::DetectorInterpolation: Copy sinogram " << sinogram.index() << " to device finished.";
   }
}

auto DetectorInterpolation::readConfig(const std::string& configFile) -> bool {
   ConfigReader configReader = ConfigReader(configFile.data());
   int samplingRate, scanRate;
   if (configReader.lookupValue("numberOfFanDetectors", numberOfDetectors_)
         && configReader.lookupValue("thresh_min", threshMin_)
         && configReader.lookupValue("thresh_max", threshMax_)
         && configReader.lookupValue("samplingRate", samplingRate)
         && configReader.lookupValue("scanRate", scanRate)){
      numberOfProjections_ = samplingRate * 1000000 / scanRate;
      return EXIT_SUCCESS;
   }
   else
      return EXIT_FAILURE;

}

}
}
