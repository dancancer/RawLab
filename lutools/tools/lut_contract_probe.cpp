#include "sony2fuji/lut_parser.h"
#include "core/photo_lut_contract.h"
#include "nlohmann/json.hpp"
#include <iomanip>
#include <iostream>

int main(int argc,char** argv) {
    if (argc<3) { std::cerr<<"Usage: rawlab_lut_probe inspect FILE | evaluate FILE scene|display\n";return 2; }
    try {
        auto lut=std::shared_ptr<sony2fuji::LUT3D>(sony2fuji::LUTParser::loadLUT(argv[2]));
        if(!lut) { std::cerr<<"Invalid CUBE/VLT data\n";return 2; }
        if(std::string(argv[1])=="inspect") {
            const char* states[]={"missing_color","missing_reference","unsupported_contract","invalid_contract","declared_unverified","legacy_declaration","unreadable","compatibility","approximate_base"};
            nlohmann::json report={{"state",states[int(lut->contractState())]},
                {"native_photo_compatible",lut->isPhotoLUT()},{"size",lut->getSize()},
                {"format",lut->isVLT()?"vlt":"cube"},{"appearance","unverified"}};
            std::cout<<report.dump()<<'\n';return 0;
        }
        if(std::string(argv[1])!="evaluate" || argc!=4 ||
            (std::string(argv[3])!="scene" && std::string(argv[3])!="display") ||
            !lut->isPhotoLUT() || !lut->hasColorContract()) return 2;
        sony2fuji::ContractLUTEvaluator evaluator(lut);
        if(!evaluator.supportsInput(std::string(argv[3])=="display")) return 2;
        sony2fuji::RGB input;
        std::cout<<std::setprecision(9);
        while(std::cin>>input.r>>input.g>>input.b) {
            if(!std::isfinite(input.r)||!std::isfinite(input.g)||!std::isfinite(input.b)) return 2;
            auto result=evaluator.apply(input);
            if(!std::isfinite(result.r)||!std::isfinite(result.g)||!std::isfinite(result.b)) return 2;
            std::cout<<result.r<<' '<<result.g<<' '<<result.b<<'\n';
        }
        return std::cin.eof()?0:2;
    } catch(const std::exception& error) { std::cerr<<error.what()<<'\n';return 2; }
}
