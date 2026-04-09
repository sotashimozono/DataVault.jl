# util/enumerate.jl — DataKey の列挙

"""
    keys(vault; status=:all) -> Vector{DataKey}

Enumerate `DataKey`s for this study.

- `status=:all`     — all keys (default)
- `status=:done`    — only keys with a `.done` file
- `status=:pending` — only keys without a `.done` file
"""
function keys(vault::Vault; status::Symbol=:all)::Vector{DataKey}
    all = ParamIO.expand(vault.spec)
    status == :all && return all
    status == :done && return filter(k -> is_done(vault, k), all)
    status == :pending && return filter(k -> !is_done(vault, k), all)
    error("Unknown status :$status — use :all, :done, or :pending")
end
