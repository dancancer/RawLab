using System.IO;
using System.Windows.Media.Imaging;

namespace RawLab.Windows;

internal static class ExportMetadata
{
    // 进程生命周期与常驻管道细节统一收敛在 ExifToolSession。
    internal static string VerifyAvailable() => ExifToolSession.ExecutablePath();
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
            throw new InvalidOperationException(Loc.Text("不能覆盖原始文件。"));
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

    // 整批复用常驻 ExifTool 进程；启动失败时 ExifToolSession 内部回退单次调用。
    internal static string Run(IEnumerable<string> arguments) => ExifToolSession.Run(arguments);
}
