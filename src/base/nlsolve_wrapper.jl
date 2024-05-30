struct NLsolveWrapper
    zero::Vector{Float64}
    converged::Bool
    failed::Bool
end

NLsolveWrapper() = NLsolveWrapper(Vector{Float64}(), false, true)
converged(sol::NLsolveWrapper) = sol.converged
failed(sol::NLsolveWrapper) = sol.failed

function _get_model_closure(
    model::SystemModel{MassMatrixModel, NoDelays},
    ::Vector{Float64},
    p::AbstractArray{Float64},
)
    return (residual, x, p) -> model(residual, x, p, 0.0)
end

function _get_model_closure(
    model::SystemModel{MassMatrixModel, HasDelays},
    x0::Vector{Float64},
    p::AbstractArray{Float64},
)
    h(p, t; idxs = nothing) = typeof(idxs) <: Number ? x0[idxs] : x0
    return (residual, x, p) -> model(residual, x, h, p, 0.0)
end

function _get_model_closure(
    model::SystemModel{ResidualModel, NoDelays},
    x0::Vector{Float64},
    p::AbstractArray{Float64},
)
    dx0 = zeros(length(x0))
    return (residual, x, p) -> model(residual, dx0, x, p, 0.0)
end

function _nlsolve_call(
    initial_guess::Vector{Float64},
    p::AbstractArray,
    f_eval::Function,
    jacobian::JacobianFunctionWrapper,
    f_tolerance::Float64,
    solver::NonlinearSolve.AbstractNonlinearSolveAlgorithm,
    show_trace::Bool,
)
    f = SciMLBase.NonlinearFunction(f_eval; jac = jacobian)
    prob = NonlinearSolve.NonlinearProblem(f, initial_guess, p)
    sol = NonlinearSolve.solve(
        prob,
        solver;
        abstol = f_tolerance,
        reltol = f_tolerance,
        maxiters = MAX_NLSOLVE_INTERATIONS,
        show_trace = Val(show_trace),
    )
    return NLsolveWrapper(sol.u, SciMLBase.successful_retcode(sol), false)
end

function _convergence_check(
    sys_solve::NLsolveWrapper,
    tol::Float64,
    solv::NonlinearSolve.AbstractNonlinearSolveAlgorithm,
)
    if converged(sys_solve)
        CRC.@ignore_derivatives @warn(
            "Initialization non-linear solve succeeded with a tolerance of $(tol) using solver $(solv). Saving solution."
        )
    else
        CRC.@ignore_derivatives @warn(
            "Initialization non-linear solve convergence failed, initial conditions do not meet conditions for an stable equilibrium.\nAttempting again with reduced numeric tolerance and using another solver"
        )
    end
    return converged(sys_solve)
end

function _sorted_residuals(residual::Vector{Float64})
    if isapprox(sum(abs.(residual)), 0.0; atol = STRICT_NLSOLVE_F_TOLERANCE)
        CRC.@ignore_derivatives @debug "Residual is zero with tolerance $(STRICT_NLSOLVE_F_TOLERANCE)"
        return
    end
    ix_sorted = sortperm(abs.(residual); rev = true)
    show_residual = min(10, length(residual))
    for i in 1:show_residual
        ix = ix_sorted[i]
        CRC.@ignore_derivatives @debug ix abs(residual[ix])
    end
    return
end

function _check_residual(
    residual::Vector{Float64},
    inputs::SimulationInputs,
    tolerance::Float64,
)
    CRC.@ignore_derivatives @debug _sorted_residuals(residual)
    val, ix = findmax(residual)
    sum_residual = sum(abs.(residual))
    CRC.@ignore_derivatives @info "Residual from initial guess: max = $(val) at $ix, total = $sum_residual"
    if sum_residual > tolerance
        state_map = make_global_state_map(inputs)
        for (k, val) in state_map
            get_global_state_map(inputs)[k] = val
        end
        gen_name = ""
        state = ""
        for (gen, states) in state_map
            for (state_name, index) in states
                if index == ix
                    gen_name = gen
                    state = state_name
                end
            end
        end
        if gen_name != ""
            error("The initial residual in the state located at $ix has a value of $val.
                Generator = $gen_name, state = $state.
               Residual error is too large to continue")
        else
            bus_count = get_bus_count(inputs)
            bus_no = ix > bus_count ? ix - bus_count : ix
            component = ix > bus_count ? "imag" : "real"
            error("The initial residual in the state located at $ix has a value of $val.
                Voltage at bus = $bus_no, component = $component.
                Error is too large to continue")
        end
    end
    return
end

function refine_initial_condition!(
    sim::Simulation,
    model::SystemModel,
    jacobian::JacobianFunctionWrapper,
    ::Val{POWERFLOW_AND_DEVICES},
)
    @assert sim.status != BUILD_INCOMPLETE
    converged = false
    initial_guess = get_x0(sim)
    inputs = get_simulation_inputs(sim)
    parameters = get_parameters(inputs)
    bus_range = get_bus_range(inputs)
    powerflow_solution = deepcopy(initial_guess[bus_range])
    f! = _get_model_closure(model, initial_guess, parameters)
    residual = similar(initial_guess)
    f!(residual, initial_guess, parameters)
    _check_residual(residual, inputs, MAX_INIT_RESIDUAL)
    for tol in [STRICT_NLSOLVE_F_TOLERANCE, RELAXED_NLSOLVE_F_TOLERANCE]
        if converged
            break
        end
        for solv in [NonlinearSolve.TrustRegion(), NonlinearSolve.NewtonRaphson()]
            CRC.@ignore_derivatives @debug "Start NLSolve System Run with $(solv) and F_tol = $tol"
            show_trace = sim.console_level <= Logging.Info
            sys_solve = _nlsolve_call(
                initial_guess,
                parameters,
                f!,
                jacobian,
                tol,
                solv,
                show_trace,
            )
            failed(sys_solve) && return BUILD_FAILED
            converged = _convergence_check(sys_solve, tol, solv)
            CRC.@ignore_derivatives @debug "Write initial guess vector using $solv with tol = $tol convergence = $converged"
            initial_guess .= sys_solve.zero
            if converged
                break
            end
        end
    end

    sim.status = check_valid_values(initial_guess, inputs)
    if sim.status == BUILD_FAILED
        error(
            "Initial conditions refinement failed to find a valid initial condition. Run show_states_initial_value on your simulation",
        )
    end

    f!(residual, initial_guess, parameters)
    if !converged || (sum(residual) > MINIMAL_ACCEPTABLE_NLSOLVE_F_TOLERANCE)
        _check_residual(residual, inputs, MINIMAL_ACCEPTABLE_NLSOLVE_F_TOLERANCE)
        CRC.@ignore_derivatives @warn(
            "Initialization didn't found a solution to desired tolerances.\\
Initial conditions do not meet conditions for an stable equilibrium. \\
Simulation might fail"
        )
    end

    pf_diff = abs.(powerflow_solution .- initial_guess[bus_range])
    if maximum(pf_diff) > MINIMAL_ACCEPTABLE_NLSOLVE_F_TOLERANCE
        CRC.@ignore_derivatives @warn "The resulting voltages in the initial conditions differ from the power flow results"
    end
    return
end

function refine_initial_condition!(
    sim::Simulation,
    model::SystemModel,
    jacobian::JacobianFunctionWrapper,
    ::Val{DEVICES_ONLY},
)
    refine_initial_condition!(sim, model, jacobian, Val(POWERFLOW_AND_DEVICES))
end

function refine_initial_condition!(
    sim::Simulation,
    model::SystemModel,
    jacobian::JacobianFunctionWrapper,
    ::Val{FLAT_START},
)
end
function refine_initial_condition!(
    sim::Simulation,
    model::SystemModel,
    jacobian::JacobianFunctionWrapper,
    ::Val{INITIALIZED},
)
end
