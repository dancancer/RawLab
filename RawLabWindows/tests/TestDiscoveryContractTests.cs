using System.Reflection;
using Xunit;

namespace RawLab.Windows.Tests;

[Trait("Category", "Model")]
public sealed class TestDiscoveryContractTests
{
    private static readonly HashSet<string> KnownCategories = new(StringComparer.Ordinal)
    {
        "Model",
        "WpfModel",
        "Native",
        "BatchSelection",
        "AI",
        "Benchmark",
        "OfflineInstaller",
    };

    private static readonly HashSet<string> KnownRunV08Suites = new(StringComparer.Ordinal)
    {
        "editing",
        "looks",
        "denoise-model",
        "localization",
        "updates",
        "comparison",
        "about",
        "default-isolation",
        "localization-admission",
        "profile-isolation",
        "localization-ui",
        "unhandled-ui",
        "entry-selection",
        "ai-panel",
        "ai-window",
        "editor-shell",
        "geometry",
        "master-recipes",
        "rendered-dng",
        "denoise",
        "lens",
        "agent-recipe",
        "raster",
        "batch-selection",
        "recipe-white-balance",
        "atmosphere-render",
        "tone-render",
        "grading-render",
        "curve-render",
        "hsl-target-render",
        "inspection-suite",
        "x3f",
        "hdr-workflow",
        "first-preview",
        "hdr-look-import",
        "agent-hot-reload",
    };

    private static readonly Dictionary<string, string> DedicatedSuitesByCategory = new(StringComparer.Ordinal)
    {
        ["Native"] = "default",
        ["AI"] = "ai-denoise",
        ["Benchmark"] = "benchmark",
        ["OfflineInstaller"] = "updates-sdk-offline",
    };

    [Fact]
    public void EveryXunitTestMethodBelongsToAKnownRunnerCategoryOrSuite()
    {
        var assembly = typeof(TestDiscoveryContractTests).Assembly;
        var discoveredSuites = new HashSet<string>(StringComparer.Ordinal);
        var modelTests = 0;
        var totalTests = 0;

        foreach (var type in assembly.GetTypes())
        {
            var typeTraits = ReadTraits(type.GetCustomAttributesData());
            foreach (var method in type.GetMethods(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly))
            {
                if (!HasXunitFactAttribute(method))
                    continue;

                totalTests++;
                Assert.True(type.IsPublic && !type.IsAbstract, $"xUnit test type must be public concrete: {type.FullName}");
                Assert.True(method.IsPublic, $"xUnit test method must be public: {type.FullName}.{method.Name}");

                var traits = MergeTraits(typeTraits, ReadTraits(method.GetCustomAttributesData()));
                Assert.True(traits.TryGetValue("Category", out var categories) && categories.Count > 0,
                    $"Orphan xUnit test missing Category trait: {type.FullName}.{method.Name}");

                foreach (var category in categories)
                {
                    Assert.Contains(category, KnownCategories);
                }

                var isModel = categories.Contains("Model");
                if (isModel)
                {
                    modelTests++;
                }

                traits.TryGetValue("Suite", out var suites);
                if (suites != null)
                {
                    foreach (var suite in suites)
                    {
                        Assert.False(string.IsNullOrWhiteSpace(suite),
                            $"Blank Suite trait on {type.FullName}.{method.Name}");
                        discoveredSuites.Add(suite);

                        var allowedDedicated = categories.Any(c =>
                            DedicatedSuitesByCategory.TryGetValue(c, out var dedicated) && dedicated == suite);
                        Assert.True(KnownRunV08Suites.Contains(suite) || allowedDedicated,
                            $"Test {type.FullName}.{method.Name} declares unknown Suite '{suite}'. Register it in run-v08.ps1 or document its dedicated runner.");
                    }
                }
                else
                {
                    Assert.True(isModel,
                        $"Non-Model xUnit test {type.FullName}.{method.Name} (Categories: {string.Join(", ", categories)}) must declare a Suite trait so a runner can execute it.");
                }
            }
        }

        Assert.True(totalTests > 0, "Expected at least one xUnit test in RawLabWindows.Tests.");
        Assert.True(modelTests > 0, "Expected at least one Category=Model test in RawLabWindows.Tests.");

        var missingRunV08Suites = KnownRunV08Suites.Where(suite => !discoveredSuites.Contains(suite)).ToArray();
        Assert.True(missingRunV08Suites.Length == 0,
            "run-v08.ps1 declares suites with no matching xUnit test: " + string.Join(", ", missingRunV08Suites));
    }

    private static bool HasXunitFactAttribute(MethodInfo method) =>
        method.GetCustomAttributes(inherit: true).Any(attr => attr is FactAttribute);

    private static Dictionary<string, List<string>> ReadTraits(IList<CustomAttributeData> attributes)
    {
        var result = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var data in attributes)
        {
            if (data.AttributeType != typeof(TraitAttribute) || data.ConstructorArguments.Count != 2)
                continue;
            var key = data.ConstructorArguments[0].Value as string;
            var value = data.ConstructorArguments[1].Value as string;
            if (string.IsNullOrEmpty(key) || value == null)
                continue;
            if (!result.TryGetValue(key, out var list))
            {
                list = [];
                result[key] = list;
            }
            list.Add(value);
        }
        return result;
    }

    private static Dictionary<string, List<string>> MergeTraits(
        Dictionary<string, List<string>> typeTraits,
        Dictionary<string, List<string>> methodTraits)
    {
        var merged = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var source in new[] { typeTraits, methodTraits })
        {
            foreach (var (key, values) in source)
            {
                if (!merged.TryGetValue(key, out var list))
                {
                    list = [];
                    merged[key] = list;
                }
                list.AddRange(values);
            }
        }
        return merged;
    }
}
