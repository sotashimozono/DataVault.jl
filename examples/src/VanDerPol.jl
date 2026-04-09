module VanDerPol

export vanderpol!, rk4_solve, extract_observables

# ── ODE definition ────────────────────────────────────────────────────────────

"""
    vanderpol!(du, u, μ)

In-place Van der Pol vector field:
  ẋ = y
  ẏ = μ(1 - x²)y - x
"""
function vanderpol!(du::Vector{Float64}, u::Vector{Float64}, μ::Float64)
    x, y = u
    du[1] = y
    du[2] = μ * (1.0 - x^2) * y - x
end

# ── RK4 integrator ────────────────────────────────────────────────────────────

"""
    rk4_solve(μ, u0, t_end, dt) -> (ts, xs, ys)

Integrate the Van der Pol equation using fixed-step RK4.
Returns time, x, and y trajectories as vectors.
"""
function rk4_solve(μ::Float64, u0::Vector{Float64}, t_end::Float64, dt::Float64)
    n = round(Int, t_end / dt)
    ts = Vector{Float64}(undef, n + 1)
    xs = Vector{Float64}(undef, n + 1)
    ys = Vector{Float64}(undef, n + 1)

    u = copy(u0)
    du1 = zeros(2)
    du2 = zeros(2)
    du3 = zeros(2)
    du4 = zeros(2)
    tmp = zeros(2)

    ts[1] = 0.0
    xs[1] = u[1]
    ys[1] = u[2]

    for i in 1:n
        # k1
        vanderpol!(du1, u, μ)
        # k2
        tmp .= u .+ (dt / 2) .* du1
        vanderpol!(du2, tmp, μ)
        # k3
        tmp .= u .+ (dt / 2) .* du2
        vanderpol!(du3, tmp, μ)
        # k4
        tmp .= u .+ dt .* du3
        vanderpol!(du4, tmp, μ)

        u .+= (dt / 6) .* (du1 .+ 2 .* du2 .+ 2 .* du3 .+ du4)

        ts[i + 1] = i * dt
        xs[i + 1] = u[1]
        ys[i + 1] = u[2]
    end

    ts, xs, ys
end

# ── Observables ───────────────────────────────────────────────────────────────

"""
    extract_observables(ts, xs, ys; discard_frac=0.5) -> Dict

Compute scalar observables from the trajectory.
Discards the first `discard_frac` of the trajectory as transient.

Returns:
- `amplitude`: max |x| in the steady-state window
- `period`:    mean period estimated from zero-crossings of x (rising)
- `energy`:    mean (x² + y²) / 2 in steady-state window
"""
function extract_observables(
    ts::Vector{Float64}, xs::Vector{Float64}, ys::Vector{Float64}; discard_frac::Float64=0.5
)::Dict{String,Any}
    n_start = round(Int, length(ts) * discard_frac) + 1

    ts_ss = ts[n_start:end]
    xs_ss = xs[n_start:end]
    ys_ss = ys[n_start:end]

    amplitude = maximum(abs, xs_ss)
    energy = mean(xs_ss .^ 2 .+ ys_ss .^ 2) / 2.0

    # Period from rising zero-crossings of x
    crossings = Int[]
    for i in 2:length(xs_ss)
        if xs_ss[i - 1] < 0 && xs_ss[i] >= 0
            push!(crossings, i)
        end
    end

    period = if length(crossings) >= 2
        Δt = ts_ss[crossings[end]] - ts_ss[crossings[1]]
        Δt / (length(crossings) - 1)
    else
        NaN
    end

    Dict{String,Any}(
        "amplitude" => amplitude,
        "period" => period,
        "energy" => energy,
        "ts" => ts_ss,
        "xs" => xs_ss,
        "ys" => ys_ss,
    )
end

mean(v) = sum(v) / length(v)

end # module VanDerPol
