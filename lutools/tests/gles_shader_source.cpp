#include <iostream>
#include <string>
#include "gpu/gles_photo_shader.h"
int main(int argc, char** argv) {
    if (argc > 1 && std::string(argv[1]) == "--spatial") {
        std::cout << sony2fuji::kPhotoSpatialShader;
    } else {
        std::cout << sony2fuji::kPhotoComputeShader;
    }
}
