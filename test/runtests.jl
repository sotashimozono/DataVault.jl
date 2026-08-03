ENV["GKSwstype"] = "100"

using DataVault, ParamIO, Test, TOML
using TestShards

# Every `test_*.jl` under `test/`, in a deterministic order, each one its own shardable unit.
# `@shard` shadows `include` inside the block, so a unit is whatever this loop includes — a new
# file, or a whole new directory, is picked up by being on disk rather than by being added to
# the `dirs` list that used to sit here and could disagree with the tree.
#
# `test/vault/fixtures/` holds TOML data, not code, and carries no `test_` prefix, so it is not
# picked up. Shared Julia fixtures, if this suite ever grows any, belong ABOVE this block: a
# helper included inside becomes a unit of its own and lands on ONE shard, and every test file
# on the other shards that needed it fails.
#
# A bare `Pkg.test()` with nothing set in the environment runs all of it, in this order. Run one
# shard locally with `TESTSHARDS_ID=s2 TESTSHARDS_N=4 julia --project -e 'using Pkg; Pkg.test()'`.
TestShards.@shard begin
    for (dir, _, files) in sort!(collect(walkdir(@__DIR__)); by=first)
        for f in sort(files)
            startswith(f, "test_") && endswith(f, ".jl") || continue
            include(joinpath(dir, f))
        end
    end
end
