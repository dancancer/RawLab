using System.Text.RegularExpressions;

// ┌──────────────────────────────────────────────────────────────────────┐
// │ 翻译键必须能静态检查                                                  │
// │                                                                      │
// │ Loc.Text / Loc.Format 的第一个参数只能是字面量键，或者引用写好整键的表；│
// │ 拼接、插值、string.Concat/Format/Join 让键在运行时才出现，目录检查     │
// │ 看不到它，漏翻译时界面只会静悄悄地显示中文。                            │
// └──────────────────────────────────────────────────────────────────────┘
internal static class StaticKeyChecks
{
    private static readonly Regex Call = new(@"\bLoc\.(?:Text|Format)\(");
    private static readonly Regex Builder = new(@"\b[Ss]tring\.(?:Concat|Format|Join)\(");

    internal sealed record KeyArgument(string Location, string Text);

    internal static string SourceDirectory()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory != null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "RawLabWindows.csproj"))) return directory.FullName;
        throw new DirectoryNotFoundException("Cannot locate RawLabWindows.csproj above " + AppContext.BaseDirectory);
    }

    internal static IEnumerable<KeyArgument> Arguments(string directory) =>
        Directory.GetFiles(directory, "*.cs", SearchOption.AllDirectories)
        .Where(file => !Path.GetRelativePath(directory, file).Split(Path.DirectorySeparatorChar)
            .Any(part => part is "tests" or "bin" or "obj"))
        .Order(StringComparer.Ordinal).SelectMany(file =>
        {
            var source = File.ReadAllText(file);
            return Call.Matches(source).Select(call => new KeyArgument(
                $"{Path.GetRelativePath(directory, file)}:{Line(source, call.Index)}",
                FirstArgument(source, call.Index + call.Length)));
        });

    // ─── 顶层 '+'（下标里的算术除外）、插值字符串或字符串构造方法 ───
    internal static bool IsComposed(string argument)
    {
        if (Builder.IsMatch(argument)) return true;
        var brackets = 0;
        for (var i = 0; i < argument.Length; i++)
        {
            var c = argument[i];
            if (c == '$' && i + 1 < argument.Length && argument[i + 1] is '"' or '@') return true;
            if (c is '"' or '\'') { i = SkipLiteral(argument, i); continue; }
            brackets += c == '[' ? 1 : c == ']' ? -1 : 0;
            if (c == '+' && brackets == 0) return true;
        }
        return false;
    }

    // ─── 参数里出现的字符串字面量：这些都必须是目录中的键 ───
    internal static IEnumerable<string> Literals(string argument)
    {
        for (var i = 0; i < argument.Length; i++)
        {
            if (argument[i] is not ('"' or '\'')) continue;
            var end = SkipLiteral(argument, i);
            if (argument[i] == '"') yield return Regex.Unescape(argument[(i + 1)..end]);
            i = end;
        }
    }

    // ─── 扫描到顶层逗号或右括号为止，跳过字符串与字符字面量 ───
    private static string FirstArgument(string source, int start)
    {
        var depth = 0;
        var i = start;
        for (; i < source.Length; i++)
        {
            var c = source[i];
            if (c is '"' or '\'') { i = SkipLiteral(source, i); continue; }
            if (c is '(' or '[' or '{') depth++;
            else if (c is ')' or ']' or '}') { if (depth == 0) break; depth--; }
            else if (c == ',' && depth == 0) break;
        }
        return source[start..i].Trim();
    }

    // ─── 返回结束引号的位置；逐字字符串的 "" 会被当作相邻的两个字面量 ───
    private static int SkipLiteral(string text, int start)
    {
        var quote = text[start];
        var verbatim = start > 0 && text[start - 1] == '@';
        var i = start + 1;
        for (; i < text.Length && text[i] != quote; i++)
            if (text[i] == '\\' && !verbatim) i++;
        return i;
    }

    private static int Line(string source, int index) => source.AsSpan(0, index).Count('\n') + 1;
}
