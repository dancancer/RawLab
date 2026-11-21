using Xunit;

namespace RawLab.Windows.Tests;

[Trait("Category", "Model")]
[Trait("Suite", "updates")]
public sealed class UpdateChecksTests
{
    [Fact]
    public void InstallStateAndUpdateStorePersistAndRecover()
    {
        static void Check(bool condition, string label) => Assert.True(condition, label);

        InstallStateChecks.Run(Check);
        UpdateStoreChecks.Run(Check);
    }
}
