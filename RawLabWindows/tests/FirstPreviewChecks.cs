using System.IO;
using System.Security.Cryptography;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using RawLab.Windows;

internal static class FirstPreviewChecks
{
    internal static void Run(IEnumerable<string> photos,Action<bool,string> check)
    {
        var directory=Path.Combine(Path.GetTempPath(),"rawlab-first-preview-"+Guid.NewGuid().ToString("N"),"中文目录");
        Directory.CreateDirectory(directory);
        try
        {
            const int width=2000,height=1200;
            var pixels=new byte[width*height*3];
            for(var p=0;p<pixels.Length;p+=3){pixels[p]=211;pixels[p+1]=53;pixels[p+2]=17;}
            var bitmap=BitmapSource.Create(width,height,96,96,PixelFormats.Rgb24,null,pixels,width*3);
            bitmap.Freeze();
            using var engine=new RenderEngine(0);
            foreach(var (extension,encoder) in new (string,BitmapEncoder)[]{
                ("png",new PngBitmapEncoder()),("jpg",new JpegBitmapEncoder{QualityLevel=96}),
                ("tiff",new TiffBitmapEncoder{Compression=TiffCompressOption.None})})
            {
                var path=Path.Combine(directory,"颜色锚点."+extension);
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using(var output=File.Create(path))encoder.Save(output);
                Verify(path,true);
            }
            foreach(var source in photos)
            {
                var before=SHA256.HashData(File.ReadAllBytes(source));
                var path=Path.Combine(directory,"用户样片-"+Path.GetFileName(source));
                File.Copy(source,path);
                Verify(path,false);
                check(before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(source))) &&
                    before.SequenceEqual(SHA256.HashData(File.ReadAllBytes(path))),
                    "First preview leaves the supplied photo unchanged: "+Path.GetFileName(source));
            }

            void Verify(string path,bool anchor)
            {
                var full=engine.Render(path,new(),null,0,statistics:false,clipping:false)!.Image;
                var expected=Means(full);
                if(anchor)check(expected.Zip(new double[]{17,53,211},(a,b)=>Math.Abs(a-b)).Max()<=2,
                    "Full decode preserves the known RGB anchor: "+Path.GetExtension(path));
                foreach(var edge in new[]{180,1600})
                {
                    var preview=RenderEngine.ReadEmbeddedPreview(path,edge);
                    check(preview.Image!=null && preview.Image.IsFrozen && preview.Width==full.PixelWidth &&
                        preview.Height==full.PixelHeight && Math.Max(preview.Image.PixelWidth,preview.Image.PixelHeight)==
                        Math.Min(edge,Math.Max(full.PixelWidth,full.PixelHeight)),
                        "First preview reports bounded, oriented dimensions: "+Path.GetFileName(path)+" @"+edge);
                    var actual=Means(preview.Image!);
                    var error=expected.Zip(actual,(a,b)=>Math.Abs(a-b)).Max();
                    Console.WriteLine($"First preview color error {error:F4}: {Path.GetFileName(path)} @{edge}");
                    // Fant 缩放有舍入误差，但不能改变整幅照片的通道颜色。
                    check(error<=1.5,"Thumbnail/first-frame colors match the full render: "+Path.GetFileName(path)+" @"+edge);
                }
            }
        }
        finally {Directory.Delete(Path.GetDirectoryName(directory)!,true);}
    }

    private static double[] Means(BitmapSource image)
    {
        var pixels=new byte[image.PixelWidth*image.PixelHeight*4];
        new FormatConvertedBitmap(image,PixelFormats.Bgra32,null,0).CopyPixels(pixels,image.PixelWidth*4,0);
        var sums=new long[3];
        for(var p=0;p<pixels.Length;p+=4)for(var c=0;c<3;c++)sums[c]+=pixels[p+c];
        return sums.Select(sum=>(double)sum/(image.PixelWidth*image.PixelHeight)).ToArray();
    }
}
