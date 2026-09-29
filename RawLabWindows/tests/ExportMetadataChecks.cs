using System.Buffers.Binary;
using System.IO;
using System.Text.Json;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class ExportMetadataChecks
{
    internal static JsonElement Read(string path) => JsonDocument.Parse(ExportMetadata.Run(
        ["-j", "-n", "-EXIF:all", "-GPS:all", path])).RootElement[0].Clone();

    private static void Encode(string path, bool png)
    {
        var pixels=Enumerable.Range(0,36).Select(i=>(byte)(i*7)).ToArray();
        var bitmap=BitmapSource.Create(3,2,96,96,PixelFormats.Rgb48,null,pixels,18);
        BitmapEncoder encoder=png ? new PngBitmapEncoder() : new JpegBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream=File.Create(path); encoder.Save(stream);
    }

    // Compare encoded image data, independently of the metadata reader.
    private static byte[] ImageData(string path)
    {
        var bytes=File.ReadAllBytes(path);
        if (Path.GetExtension(path)==".png")
        {
            using var data=new MemoryStream();
            for (int offset=8;offset<bytes.Length;)
            {
                var length=checked((int)BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(offset,4)));
                if (bytes.AsSpan(offset+4,4).SequenceEqual("IDAT"u8)) data.Write(bytes,offset+8,length);
                offset+=length+12;
            }
            return data.ToArray();
        }
        for (int offset=2;offset<bytes.Length;)
        {
            if (bytes[offset]!=0xff) throw new InvalidDataException("Invalid JPEG segment");
            if (bytes[offset+1]==0xda) return bytes[offset..];
            offset+=2+BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(offset+2,2));
        }
        throw new InvalidDataException("Missing JPEG scan");
    }

    internal static void Run(string output, Action<bool,string> check)
    {
        var directory=Path.Combine(output,"EXIF 中文 & 路径"); Directory.CreateDirectory(directory);
        var source=Path.Combine(directory,"原图.jpg"); Encode(source,false);
        ExportMetadata.Run(["-overwrite_original", "-Make=Fixture Camera", "-Model=Fixture Model",
            "-LensModel=Fixture 50mm", "-DateTimeOriginal=2021:03:04 05:06:07", "-ExposureTime=1/125",
            "-FNumber=2.8", "-ISO=400", "-GPSLatitude=31.2", "-GPSLatitudeRef=N",
            "-GPSLongitude=121.5", "-GPSLongitudeRef=E", "-Orientation#=6",
            "-ExifImageWidth=999", "-ExifImageHeight=777", "-ColorSpace#=65535",
            "-ThumbnailImage<="+source, source]);
        var original=File.ReadAllBytes(source);
        foreach (var png in new[]{false,true})
        {
            var path=Path.Combine(directory,png ? "导出.png" : "导出.jpg"); Encode(path,png);
            var before=ImageData(path); ExportMetadata.Preserve(source,path); var tags=Read(path);
            check(tags.GetProperty("Make").GetString()=="Fixture Camera" &&
                tags.GetProperty("LensModel").GetString()=="Fixture 50mm" &&
                tags.GetProperty("DateTimeOriginal").GetString()=="2021:03:04 05:06:07",
                $"{Path.GetExtension(path)} retains camera, lens and capture date on Unicode paths");
            check(tags.GetProperty("ISO").GetInt32()==400 &&
                Math.Abs(tags.GetProperty("ExposureTime").GetDouble()-.008)<1e-8 &&
                Math.Abs(tags.GetProperty("FNumber").GetDouble()-2.8)<1e-6 &&
                Math.Abs(tags.GetProperty("GPSLatitude").GetDouble()-31.2)<1e-6,
                "Exposure, aperture, ISO and GPS survive export");
            check(tags.GetProperty("Orientation").GetInt32()==1 &&
                tags.GetProperty("ExifImageWidth").GetInt32()==3 &&
                tags.GetProperty("ExifImageHeight").GetInt32()==2 &&
                tags.GetProperty("ColorSpace").GetInt32()==1,
                "Orientation, dimensions and sRGB describe developed pixels");
            check(!tags.TryGetProperty("ThumbnailImage",out _) && !tags.TryGetProperty("MakerNote",out _),
                "RAW thumbnails and opaque MakerNotes are excluded");
            check(before.SequenceEqual(ImageData(path)),"Metadata copy preserves compressed image data exactly");
            if (png) check(File.ReadAllBytes(path)[24]==16 &&
                File.ReadAllBytes(path).AsSpan().IndexOf("eXIf"u8)>=0,"16-bit PNG contains a standard eXIf chunk");
        }
        var plain=Path.Combine(directory,"无拍摄信息.png"); Encode(plain,true);
        var emptyOutput=Path.Combine(directory,"空元数据.jpg"); Encode(emptyOutput,false);
        ExportMetadata.Preserve(plain,emptyOutput);
        check(!Read(emptyOutput).TryGetProperty("Make",out _),"Input without shooting EXIF can still export");
        try { ExportMetadata.Preserve(source,source); throw new Exception("Source overwrite accepted"); }
        catch (InvalidOperationException) { check(true,"EXIF source overwrite rejected"); }
        check(original.SequenceEqual(File.ReadAllBytes(source)),"Metadata source remains byte-identical");
    }
}
