using System.Diagnostics;
using System.IO;
using System.Text;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

internal static class ExportMetadata
{
    internal static string VerifyAvailable()
    {
        var executable = Path.Combine(AppContext.BaseDirectory, "ExifTool", "ExifTool.exe");
        if (!File.Exists(executable)) throw new OutputWriteException("缺少 EXIF 导出组件，请重新解压完整的 RawLab 安装包。");
        return executable;
    }
    // Copy capture information only. RAW layout, MakerNotes and thumbnails describe
    // the input sensor data and must not be attached to developed pixels.
    private static readonly string[] CaptureTags = [
        "Make", "Model", "Artist", "Copyright", "ImageDescription",
        "ModifyDate", "DateTimeOriginal", "CreateDate", "SubSecTime",
        "SubSecTimeOriginal", "SubSecTimeDigitized", "OffsetTime",
        "OffsetTimeOriginal", "OffsetTimeDigitized", "CameraOwnerName", "SerialNumber",
        "LensMake", "LensModel", "LensInfo", "LensSerialNumber",
        "ExposureTime", "FNumber", "ExposureProgram", "ISO", "SensitivityType",
        "StandardOutputSensitivity", "RecommendedExposureIndex", "ISOSpeed",
        "ShutterSpeedValue", "ApertureValue", "BrightnessValue", "ExposureCompensation",
        "MaxApertureValue", "SubjectDistance", "MeteringMode", "LightSource", "Flash",
        "FocalLength", "FocalLengthIn35mmFormat", "ExposureMode", "WhiteBalance",
        "DigitalZoomRatio", "SceneCaptureType", "GainControl", "Contrast", "Saturation",
        "Sharpness", "SubjectDistanceRange", "UserComment", "ImageUniqueID"
    ];

    internal static void Preserve(string input, string output)
    {
        input=Path.GetFullPath(input); output=Path.GetFullPath(output);
        if (input.Equals(output,StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("不能覆盖原始 RAW。");
        int width,height;
        using (var stream=File.OpenRead(output))
        {
            var frame=BitmapDecoder.Create(stream,BitmapCreateOptions.DelayCreation,BitmapCacheOption.None).Frames[0];
            width=frame.PixelWidth; height=frame.PixelHeight;
        }
        var arguments=new List<string> { "-overwrite_original", "-tagsFromFile", input };
        arguments.AddRange(CaptureTags.Select(tag=>"-EXIF:"+tag));
        arguments.AddRange(["-GPS:all", "-IFD0:Orientation#=1", "-IFD0:Software=RawLab 0.2",
            $"-IFD0:ImageWidth={width}", $"-IFD0:ImageHeight={height}",
            $"-ExifIFD:ExifImageWidth={width}", $"-ExifIFD:ExifImageHeight={height}",
            "-ExifIFD:ColorSpace#=1", output]);
        Run(arguments);
    }

    internal static string Run(IEnumerable<string> arguments)
    {
        var executable=VerifyAvailable();
        var lines=arguments.ToArray();
        if (lines.Any(line=>line.Contains('\n') || line.Contains('\r')))
            throw new ArgumentException("EXIF 参数不能包含换行。");
        var start=new ProcessStartInfo(executable) {
            UseShellExecute=false, CreateNoWindow=true, RedirectStandardInput=true,
            RedirectStandardOutput=true, RedirectStandardError=true,
            StandardInputEncoding=new UTF8Encoding(false), StandardOutputEncoding=Encoding.UTF8,
            StandardErrorEncoding=Encoding.UTF8
        };
        // Disable user configuration and use a UTF-8 argument stream for Unicode paths.
        foreach (var arg in new[]{"-config","","-charset","filename=utf8","-@","-"}) start.ArgumentList.Add(arg);
        start.Environment["LC_ALL"]="C";
        using var process=Process.Start(start) ?? throw new IOException("无法启动 EXIF 导出组件。");
        var stdout=process.StandardOutput.ReadToEndAsync();
        var stderr=process.StandardError.ReadToEndAsync();
        foreach (var line in lines) process.StandardInput.WriteLine(line);
        process.StandardInput.Close();
        if (!process.WaitForExit(60000))
        {
            process.Kill(entireProcessTree:true); process.WaitForExit();
            throw new IOException("写入 EXIF 超时，未保存导出结果。");
        }
        var error=stderr.GetAwaiter().GetResult();
        var result=stdout.GetAwaiter().GetResult();
        if (process.ExitCode!=0) throw new IOException("写入 EXIF 失败："+error.Trim());
        return result;
    }
}
