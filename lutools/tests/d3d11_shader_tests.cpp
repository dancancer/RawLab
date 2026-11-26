#include "gpu/d3d11_photo_shader.h"
#include <d3dcompiler.h>
#include <d3d11shader.h>
#include <wrl/client.h>
#include <cstring>
#include <iostream>

int main() {
    using Microsoft::WRL::ComPtr;
    ComPtr<ID3DBlob> code, errors;
    const auto status = D3DCompile(sony2fuji::kD3DPhotoShader.data(), sony2fuji::kD3DPhotoShader.size(),
        "RawLab photo shader", nullptr, nullptr, "main", "cs_5_0",
        D3DCOMPILE_OPTIMIZATION_LEVEL3 | D3DCOMPILE_IEEE_STRICTNESS, 0, &code, &errors);
    if (FAILED(status)) {
        if (errors) std::cerr << static_cast<const char*>(errors->GetBufferPointer());
        return 1;
    }
    ComPtr<ID3D11ShaderReflection> reflection;
    if (FAILED(D3DReflect(code->GetBufferPointer(), code->GetBufferSize(), IID_PPV_ARGS(&reflection)))) return 1;
    auto* buffer = reflection->GetConstantBufferByName("Params");
    D3D11_SHADER_BUFFER_DESC description{};
    if (FAILED(buffer->GetDesc(&description)) || description.Size != 4624) return 1;
    const char* names[] = {"hslHue", "hslSaturation", "hslLightness"};
    for (unsigned index = 0; index < 3; ++index) {
        D3D11_SHADER_VARIABLE_DESC variable{};
        if (FAILED(buffer->GetVariableByName(names[index])->GetDesc(&variable)) ||
            variable.StartOffset != 224 + index * 32 || variable.Size != 32) return 1;
    }
    D3D11_SHADER_VARIABLE_DESC tone{};
    if (FAILED(buffer->GetVariableByName("toneControls")->GetDesc(&tone)) ||
        tone.StartOffset!=320 || tone.Size!=16) return 1;
    D3D11_SHADER_VARIABLE_DESC grading{};
    if (FAILED(buffer->GetVariableByName("colorGrading")->GetDesc(&grading)) ||
        grading.StartOffset!=336 || grading.Size!=48) return 1;
    D3D11_SHADER_VARIABLE_DESC ranges{}, tangents{};
    if (FAILED(buffer->GetVariableByName("curveRanges")->GetDesc(&ranges)) ||
        ranges.StartOffset != 384 || ranges.Size != 2048) return 1;
    if (FAILED(buffer->GetVariableByName("curveTangents")->GetDesc(&tangents)) ||
        tangents.StartOffset != 2432 || tangents.Size != 2048) return 1;
    D3D11_SHADER_VARIABLE_DESC curveCounts{}, curveFlags{}, parametricAmps{}, parametricSplits{};
    if (FAILED(buffer->GetVariableByName("curveCounts")->GetDesc(&curveCounts)) ||
        curveCounts.StartOffset != 4480 || curveCounts.Size != 16) return 1;
    if (FAILED(buffer->GetVariableByName("curveFlags")->GetDesc(&curveFlags)) ||
        curveFlags.StartOffset != 4496 || curveFlags.Size != 16) return 1;
    if (FAILED(buffer->GetVariableByName("parametricAmps")->GetDesc(&parametricAmps)) ||
        parametricAmps.StartOffset != 4512 || parametricAmps.Size != 16) return 1;
    if (FAILED(buffer->GetVariableByName("parametricSplits")->GetDesc(&parametricSplits)) ||
        parametricSplits.StartOffset != 4528 || parametricSplits.Size != 16) return 1;
    D3D11_SHADER_VARIABLE_DESC gradingGlobal{}, gradingMix{};
    if (FAILED(buffer->GetVariableByName("colorGradingGlobal")->GetDesc(&gradingGlobal)) ||
        gradingGlobal.StartOffset != 4544 || gradingGlobal.Size != 16) return 1;
    if (FAILED(buffer->GetVariableByName("colorGradingMix")->GetDesc(&gradingMix)) ||
        gradingMix.StartOffset != 4560 || gradingMix.Size != 16) return 1;
    D3D11_SHADER_VARIABLE_DESC band{}, basicV3{}, basicTone{};
    if (FAILED(buffer->GetVariableByName("band")->GetDesc(&band)) || band.StartOffset != 4576 || band.Size != 16) return 1;
    if (FAILED(buffer->GetVariableByName("basicV3")->GetDesc(&basicV3)) || basicV3.StartOffset != 4592 || basicV3.Size != 16) return 1;
    if (FAILED(buffer->GetVariableByName("basicTone")->GetDesc(&basicTone)) || basicTone.StartOffset != 4608 || basicTone.Size != 16) return 1;

    ComPtr<ID3DBlob> spatialCode, spatialErrors;
    const auto spatialStatus = D3DCompile(sony2fuji::kD3DSpatialShader.data(), sony2fuji::kD3DSpatialShader.size(),
        "RawLab spatial shader", nullptr, nullptr, "main", "cs_5_0",
        D3DCOMPILE_OPTIMIZATION_LEVEL3 | D3DCOMPILE_IEEE_STRICTNESS, 0, &spatialCode, &spatialErrors);
    if (FAILED(spatialStatus)) {
        if (spatialErrors) std::cerr << static_cast<const char*>(spatialErrors->GetBufferPointer());
        return 1;
    }
    ComPtr<ID3D11ShaderReflection> spatialReflection;
    if (FAILED(D3DReflect(spatialCode->GetBufferPointer(), spatialCode->GetBufferSize(), IID_PPV_ARGS(&spatialReflection)))) return 1;
    auto* spatialBuffer = spatialReflection->GetConstantBufferByName("SpatialParamsBuffer");
    D3D11_SHADER_BUFFER_DESC spatialDesc{};
    if (FAILED(spatialBuffer->GetDesc(&spatialDesc)) || spatialDesc.Size != sizeof(sony2fuji::SpatialGpuParams)) return 1;

    std::cout << "PASS: cs_5_0 color & spatial shaders compile; reflected constants match the 4624-byte and 224-byte host layouts\n";
    std::cout << "Shader compilation/reflection does not establish hardware GPU execution\n";
    return 0;
}
