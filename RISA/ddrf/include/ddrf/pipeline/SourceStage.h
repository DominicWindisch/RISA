#ifndef PIPELINE_SOURCESTAGE_H_
#define PIPELINE_SOURCESTAGE_H_

#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include <boost/log/trivial.hpp>

#include "../Filesystem.h"
#include "../Image.h"

#include "OutputSide.h"

namespace ddrf
{
	namespace pipeline
	{
		template <class ImageLoader>
		class SourceStage : public ImageLoader
						  , public OutputSide<Image<typename ImageLoader::manager_type>>
		{
			public:
				using output_type = Image<typename ImageLoader::manager_type>;

			public:
				SourceStage(const std::string& address, const std::string& configPath)
				: ImageLoader(address, configPath), OutputSide<output_type>(), path_{configPath}, num_{0u}, done_{false}
				{
				}

				auto run() -> void
				{
//					//auto lock = std::unique_lock<decltype(m_)>{m_};
//					auto paths = readDirectory(path_);
//
//					auto index = 0u;
//					for(auto& path : paths)
//					{
//						auto img = ImageLoader::loadImage(path, index);
//						if(img.valid())
//						{
//							this->output(std::move(img));
//							++index;
//							++num_;
//						}
//						else
//							BOOST_LOG_TRIVIAL(warning) << "SourceStage: Skipping invalid file " << path;
//					}
//
//               // all images loaded, send poisonous pill
//               BOOST_LOG_TRIVIAL(info) << "SourceStage: All source files loaded, sending poisonous pill";
//               this->output(output_type());
//               done_ = true;

				   while(true){
				      auto img = ImageLoader::loadImage();
				      if(!img.valid()){
		               // all images loaded, send poisonous pill
		               BOOST_LOG_TRIVIAL(info) << "SourceStage: All source files loaded, sending poisonous pill";
		               this->output(output_type());
		               done_ = true;
		               break;
				      }
				      this->output(std::move(img));
				      ++num_;
				   }


				}

//				auto num() noexcept -> std::uint32_t
//				{
////					auto lock = std::unique_lock<decltype(m_)>{m_};
////					while(!done_)
////						cv_.wait(lock);
////					return num_;
//				}

			private:
				std::string path_;
				std::uint32_t num_;
				bool done_;
				std::mutex m_;
				std::condition_variable cv_;
		};
	}
}


#endif /* PIPELINE_SOURCESTAGE_H_ */
