using RawLab.Windows;
using Xunit;

namespace RawLab.Windows.Tests;

public sealed class HDRSourceCacheTests
{
    private static HDRSourceInfo MakeInfo(byte seed)
    {
        var sha = Enumerable.Repeat(seed, 32).ToArray();
        return new HDRSourceInfo(HDRProbeState.Supported, 1000, 800, 1, 1, 1, 1, 2.0f, 1, sha);
    }

    private static HDRPairOwner MakeOwner(ulong hdrBytes, ulong sdrBytes, Action? onRelease = null)
    {
        var pair = new Native.HDRImagePair
        {
            Hdr = new Native.HDRBuffer { SizeBytes = hdrBytes },
            Sdr = new Native.HDRBuffer { SizeBytes = sdrBytes }
        };
        return new HDRPairOwner(pair, _ => onRelease?.Invoke());
    }

    [Fact]
    [Trait("Category", "Model")]
    public void SlowDecodeDoesNotBlockUnrelatedKeysCachedBytesOrLeaseDisposal()
    {
        HDRSourceCache.Clear();
        try
        {
            using var decodeStarted = new ManualResetEventSlim(false);
            using var allowDecodeFinish = new ManualResetEventSlim(false);
            using var keyBCompleted = new ManualResetEventSlim(false);

            var infoA = MakeInfo(1);
            var infoB = MakeInfo(2);
            var releaseCountB = 0;
            var releaseCountA = 0;

            var taskA = Task.Run(() =>
            {
                using var leaseA = HDRSourceCache.Acquire(
                    "photoA.heic",
                    infoA,
                    final: false,
                    edge: 1000,
                    decode: (_, _, _, _, _, _, _, _, _) =>
                    {
                        decodeStarted.Set();
                        Assert.True(allowDecodeFinish.Wait(TimeSpan.FromSeconds(5)));
                        return MakeOwner(1024, 1024, () => Interlocked.Increment(ref releaseCountA));
                    });
            });

            Assert.True(decodeStarted.Wait(TimeSpan.FromSeconds(5)));

            ulong observedBytes = 0;
            var taskB = Task.Run(() =>
            {
                using (var leaseB = HDRSourceCache.Acquire(
                    "photoB.heic",
                    infoB,
                    final: false,
                    edge: 1000,
                    decode: (_, _, _, _, _, _, _, _, _) =>
                        MakeOwner(2048, 2048, () => Interlocked.Increment(ref releaseCountB))))
                {
                    observedBytes = HDRSourceCache.CachedBytes;
                    Assert.Equal(4096UL, observedBytes);
                }
                keyBCompleted.Set();
            });

            Assert.True(keyBCompleted.Wait(TimeSpan.FromSeconds(3)), "Unrelated key B and CachedBytes must not block behind key A decode");
            HDRSourceCache.Clear();
            Assert.Equal(0UL, HDRSourceCache.CachedBytes);
            Assert.Equal(1, releaseCountB);

            allowDecodeFinish.Set();
            taskA.GetAwaiter().GetResult();
            taskB.GetAwaiter().GetResult();
            Assert.Equal(1, releaseCountA);
        }
        finally
        {
            HDRSourceCache.Clear();
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public void EightConcurrentAcquireCallsDeduplicateDecodeAndTrackRefcountAcrossClear()
    {
        HDRSourceCache.Clear();
        try
        {
            var info = MakeInfo(3);
            var decodeCount = 0;
            var releaseCount = 0;
            using var leaderEntered = new ManualResetEventSlim(false);
            using var releaseLeader = new ManualResetEventSlim(false);
            using var allQueued = new CountdownEvent(8);

            var owners = new HDRPairOwner[8];
            var leases = new HDRSourceLease[8];

            var leaderTask = Task.Run(() =>
            {
                leases[0] = HDRSourceCache.Acquire(
                    "shared.heic",
                    info,
                    final: false,
                    edge: 1600,
                    decode: (_, _, _, _, _, _, _, _, _) =>
                    {
                        Interlocked.Increment(ref decodeCount);
                        leaderEntered.Set();
                        allQueued.Signal();
                        Assert.True(releaseLeader.Wait(TimeSpan.FromSeconds(5)));
                        return MakeOwner(4096, 4096, () => Interlocked.Increment(ref releaseCount));
                    });
                owners[0] = leases[0].Owner;
            });

            Assert.True(leaderEntered.Wait(TimeSpan.FromSeconds(5)));

            var waiterTasks = Enumerable.Range(1, 7).Select(idx => Task.Run(() =>
            {
                allQueued.Signal();
                leases[idx] = HDRSourceCache.Acquire(
                    "shared.heic",
                    info,
                    final: false,
                    edge: 1600,
                    decode: (_, _, _, _, _, _, _, _, _) =>
                    {
                        Interlocked.Increment(ref decodeCount);
                        return MakeOwner(4096, 4096, () => Interlocked.Increment(ref releaseCount));
                    });
                owners[idx] = leases[idx].Owner;
            })).ToArray();

            Assert.True(allQueued.Wait(TimeSpan.FromSeconds(5)));
            // Give waiters a moment to enter InFlight wait under Gate before releasing leader.
            Thread.Sleep(50);
            releaseLeader.Set();

            leaderTask.GetAwaiter().GetResult();
            Task.WaitAll(waiterTasks);

            Assert.Equal(1, decodeCount);
            for (var i = 1; i < 8; i++)
                Assert.True(ReferenceEquals(owners[0], owners[i]));

            HDRSourceCache.Clear();
            Assert.Equal(0, releaseCount);

            for (var i = 0; i < 7; i++)
            {
                leases[i].Dispose();
                Assert.Equal(0, releaseCount);
            }

            // Idempotent dispose on already-disposed lease must not decrement Users twice.
            leases[0].Dispose();
            Assert.Equal(0, releaseCount);

            leases[7].Dispose();
            Assert.Equal(1, releaseCount);
        }
        finally
        {
            HDRSourceCache.Clear();
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public void LeaderCancellationDoesNotFailWaiter()
    {
        HDRSourceCache.Clear();
        try
        {
            var info = MakeInfo(4);
            var decodeCalls = 0;
            var releaseCount = 0;
            using var leaderEntered = new ManualResetEventSlim(false);
            using var cancelLeader = new ManualResetEventSlim(false);

            var leaderTask = Task.Run(() =>
            {
                Assert.Throws<OperationCanceledException>(() =>
                    HDRSourceCache.Acquire(
                        "cancel.heic",
                        info,
                        final: false,
                        edge: 1200,
                        decode: (_, _, _, _, _, _, _, _, _) =>
                        {
                            Interlocked.Increment(ref decodeCalls);
                            leaderEntered.Set();
                            Assert.True(cancelLeader.Wait(TimeSpan.FromSeconds(5)));
                            throw new OperationCanceledException();
                        }));
            });

            Assert.True(leaderEntered.Wait(TimeSpan.FromSeconds(5)));

            var waiterTask = Task.Run(() =>
            {
                using var lease = HDRSourceCache.Acquire(
                    "cancel.heic",
                    info,
                    final: false,
                    edge: 1200,
                    decode: (_, _, _, _, _, _, _, _, _) =>
                    {
                        Interlocked.Increment(ref decodeCalls);
                        return MakeOwner(2048, 2048, () => Interlocked.Increment(ref releaseCount));
                    });
                return lease.Owner;
            });

            Thread.Sleep(50);
            cancelLeader.Set();

            leaderTask.GetAwaiter().GetResult();
            var waiterOwner = waiterTask.GetAwaiter().GetResult();
            Assert.NotNull(waiterOwner);
            Assert.Equal(2, decodeCalls);

            HDRSourceCache.Clear();
            Assert.Equal(1, releaseCount);
        }
        finally
        {
            HDRSourceCache.Clear();
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public void ClearDuringInFlightDecodeKeepsCachedBytesZeroAndDisposesOnLeaseRelease()
    {
        HDRSourceCache.Clear();
        try
        {
            var info = MakeInfo(5);
            var releaseCount = 0;
            using var decodeStarted = new ManualResetEventSlim(false);
            using var allowFinish = new ManualResetEventSlim(false);

            var task = Task.Run(() =>
                HDRSourceCache.Acquire(
                    "cleared.heic",
                    info,
                    final: false,
                    edge: 1000,
                    decode: (_, _, _, _, _, _, _, _, _) =>
                    {
                        decodeStarted.Set();
                        Assert.True(allowFinish.Wait(TimeSpan.FromSeconds(5)));
                        return MakeOwner(4096, 4096, () => Interlocked.Increment(ref releaseCount));
                    }));

            Assert.True(decodeStarted.Wait(TimeSpan.FromSeconds(5)));
            HDRSourceCache.Clear();
            allowFinish.Set();

            using var lease = task.GetAwaiter().GetResult();
            Assert.Equal(0UL, HDRSourceCache.CachedBytes);
            Assert.Equal(0, releaseCount);

            lease.Dispose();
            Assert.Equal(1, releaseCount);
        }
        finally
        {
            HDRSourceCache.Clear();
        }
    }

    [Fact]
    [Trait("Category", "Model")]
    public void LruEvictionRespectsBudgetKeepsActiveLeasesAndReusesLargerEdge()
    {
        HDRSourceCache.Clear();
        try
        {
            var info1 = MakeInfo(10);
            var info2 = MakeInfo(11);
            var info3 = MakeInfo(12);
            var release1 = 0;
            var release2 = 0;
            var release3 = 0;
            const ulong chunk = 48UL * 1024 * 1024; // pair = 96 MiB? Use 24+24 = 48 MiB each.
            const ulong half = 24UL * 1024 * 1024;

            var lease1 = HDRSourceCache.Acquire(
                "one.heic", info1, false, 128,
                decode: (_, _, _, _, _, _, _, _, _) => MakeOwner(half, half, () => Interlocked.Increment(ref release1)));
            using (var smaller = HDRSourceCache.Acquire(
                "one.heic", info1, false, 64,
                decode: (_, _, _, _, _, _, _, _, _) => throw new InvalidOperationException("Should reuse edge 128")))
            {
                Assert.True(ReferenceEquals(lease1.Owner, smaller.Owner));
            }
            Assert.Equal(chunk, HDRSourceCache.CachedBytes);

            using (var lease2 = HDRSourceCache.Acquire(
                "two.heic", info2, false, 128,
                decode: (_, _, _, _, _, _, _, _, _) => MakeOwner(half, half, () => Interlocked.Increment(ref release2))))
            {
                Assert.Equal(chunk * 2, HDRSourceCache.CachedBytes);
            }

            // Adding a 3rd 48 MiB entry (144 > 128 MiB budget) evicts LRU ("one.heic"),
            // but lease1 keeps owner1 alive until lease1.Dispose().
            using (var lease3 = HDRSourceCache.Acquire(
                "three.heic", info3, false, 128,
                decode: (_, _, _, _, _, _, _, _, _) => MakeOwner(half, half, () => Interlocked.Increment(ref release3))))
            {
                Assert.True(HDRSourceCache.CachedBytes <= 128UL * 1024 * 1024);
                Assert.Equal(chunk * 2, HDRSourceCache.CachedBytes);
                Assert.Equal(0, release1);
            }

            lease1.Dispose();
            Assert.Equal(1, release1);
            Assert.Equal(0, release2);
            Assert.Equal(0, release3);

            HDRSourceCache.Clear();
            Assert.Equal(1, release2);
            Assert.Equal(1, release3);
        }
        finally
        {
            HDRSourceCache.Clear();
        }
    }
}
