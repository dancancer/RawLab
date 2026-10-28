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
    if (FAILED(buffer->GetDesc(&description)) || description.Size != 1408) return 1;
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
        ranges.StartOffset != 384 || ranges.Size != 512) return 1;
    if (FAILED(buffer->GetVariableByName("curveTangents")->GetDesc(&tangents)) ||
        tangents.StartOffset != 896 || tangents.Size != 512) return 1;
    std::cout << "PASS: cs_5_0 color shader compiles; reflected constants match the 1408-byte host layout\n";
    std::cout << "Shader compilation/reflection does not establish hardware GPU execution\n";
    return 0;
}
