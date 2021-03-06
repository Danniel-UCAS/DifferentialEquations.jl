@def femheat_footer begin
  u[bdnode] = gD(node,i*Δt)[bdnode]
  if save_timeseries && i%timeseries_steps==0
    push!(timeseries,u)
    push!(ts,t)
  end
  (atomloaded && progressbar && i%progress_steps==0) ? Main.Atom.progress(i/numiters) : nothing #Use Atom's progressbar if loaded
end

@def femheat_deterministicimplicitlinearsolve begin
  if solver==:Direct || solver==:Cholesky || solver==:QR || solver==:LU || solver==:SVD
    u[freenode,:] = lhs\rhs(u,i)
  elseif solver==:CG
    u[freenode],ch = cg!(u[freenode],lhs,(u,i)->vec(rhs(u,i))) # Requires Vector, need to change rhs
  elseif solver==:GMRES
    u[freenode],ch = gmres!(u[freenode],lhs,(u,i)->vec(rhs(u,i))) # Requires Vector, need to change rhs
  end
end

@def femheat_stochasticimplicitlinearsolve begin
  dW = next(rands)
  if solver==:Direct || solver==:Cholesky || solver==:QR || solver==:LU || solver==:SVD
    u[freenode,:] = lhs\rhs(u,i,dW)
  elseif solver==:CG
    u[freenode],ch = cg!(u[freenode],lhs,rhs(u,i,dW)) # Requires Vector, need to change rhs
  elseif solver==:GMRES
    u[freenode],ch = gmres!(u[freenode],lhs,rhs(u,i,dW)) # Requires Vector, need to change rhs
  end
end

@def femheat_implicitpreamble begin
  if solver==:Cholesky
    lhs = cholfact(lhs) # Requires positive definite, may be violated
  elseif solver==:LU
    lhs = lufact(lhs)
  elseif solver==:QR
    lhs = qrfact(lhs) #More stable, slower than LU
  elseif solver==:SVD
    lhs = svdfact(lhs)
  end
end

@def femheat_nonlinearsolvestochasticloop begin
  u = vec(u)
  uOld = copy(u)
  dW = next(rands)
  nlres = NLsolve.nlsolve((u,resid)->rhs!(u,resid,dW,uOld,i),uOld,autodiff=autodiff,method=method,show_trace=show_trace,iterations=iterations)
  u = nlres.zero
  if numvars > 1
    u = reshape(u,N,numvars)
  end
end

@def femheat_nonlinearsolvedeterministicloop begin
  u = vec(u)
  uOld = copy(u)
  nlres = NLsolve.nlsolve((u,resid)->rhs!(u,resid,uOld,i),uOld,autodiff=autodiff,method=method,show_trace=show_trace,iterations=iterations)
  u = nlres.zero
  if numvars > 1
    u = reshape(u,N,numvars)
  end
end

@def femheat_nonlinearsolvepreamble begin
  initialize_backend(:NLsolve)
  if autodiff
    initialize_backend(:ForwardDiff)
  end
  uOld = similar(vec(u))
end

@def femheat_deterministicpreamble begin
  @unpack integrator: N,Δt,t,Minv,D,A,freenode,f,gD,gN,u,node,elem,area,bdnode,mid,dirichlet,neumann,islinear,numvars,numiters,save_timeseries,timeseries,ts,atomloaded,solver,autodiff,method,show_trace,iterations,timeseries_steps,progressbar,progress_steps
end

@def femheat_stochasticpreamble begin
  @unpack integrator: N,Δt,t,Minv,D,A,freenode,f,gD,gN,u,node,elem,area,bdnode,mid,dirichlet,neumann,islinear,numvars,sqrtΔt,σ,noisetype,numiters,save_timeseries,timeseries,ts,atomloaded,solver,autodiff,method,show_trace,iterations,timeseries_steps,progressbar,progress_steps
  rands = getNoise(u,node,elem,noisetype=noisetype)
end

type FEMHeatIntegrator{T1,T2,T3}
  N::Int
  Δt::Float64
  t
  Minv
  D
  A
  freenode
  f::Function
  gD::Function
  gN::Function
  u
  node
  elem
  area
  bdnode
  mid
  dirichlet
  neumann
  islinear::Bool
  numvars::Int
  sqrtΔt::Float64
  σ::Function
  noisetype::Symbol
  numiters::Int
  save_timeseries::Bool
  timeseries
  ts
  atomloaded::Bool
  solver::Symbol
  autodiff::Bool
  method::Symbol
  show_trace::Bool
  iterations::Int
  timeseries_steps::Int
  progressbar::Bool
  progress_steps::Int
end

function femheat_solve(integrator::FEMHeatIntegrator{:linear,:Euler,:deterministic})
  @femheat_deterministicpreamble
  K = eye(N) - Δt*Minv*D*A #D okay since numVar = 1 for linear
  for i=1:numiters
    u[freenode,:] = K[freenode,freenode]*u[freenode,:] + (Minv*Δt*quadfbasis((x)->f(x,t),(x)->gD(x,t),(x)->gN(x,t),
                A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
    t += Δt
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:linear,:Euler,:stochastic})
  @femheat_stochasticpreamble
  K = eye(N) - Δt*Minv*D*A #D okay since numVar = 1 for linear
  for i=1:numiters
    dW = next(rands)
    u[freenode,:] = K[freenode,freenode]*u[freenode,:] + (Minv*Δt*quadfbasis((x)->f(x,t),(x)->gD(x,t),(x)->gN(x,t),
                A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:] +
                (sqrtΔt.*dW.*Minv*quadfbasis((x)->σ(x,t),(x)->gD(x,t),(x)->gN(x,t),
                            A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
    t += Δt
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:nonlinear,:Euler,:deterministic})
  @femheat_deterministicpreamble
  for i=1:numiters
    u[freenode,:] = u[freenode,:] - D.*(Δt*Minv[freenode,freenode]*A[freenode,freenode]*u[freenode,:]) + (Minv*Δt*quadfbasis((u,x)->f(u,x,t),(x)->gD(x,t),(x)->gN(x,t),
            A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
    t += Δt
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:nonlinear,:Euler,:stochastic})
  @femheat_stochasticpreamble
  for i=1:numiters
    dW = next(rands)
    u[freenode,:] = u[freenode,:] - D.*(Δt*Minv[freenode,freenode]*A[freenode,freenode]*u[freenode,:]) + (Minv*Δt*quadfbasis((u,x)->f(u,x,t),(x)->gD(x,t),(x)->gN(x,t),
                A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:] +
                (sqrtΔt.*dW.*Minv*quadfbasis((u,x)->σ(u,x,t),(x)->gD(x,t),(x)->gN(x,t),
                            A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
    t += Δt
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:linear,:ImplicitEuler,:stochastic})
  @femheat_stochasticpreamble
  K = eye(N) + Δt*Minv*D*A #D okay since numVar = 1 for linear
  lhs = K[freenode,freenode]
  rhs(u,i,dW) = u[freenode,:] + (Minv*Δt*quadfbasis((x)->f(x,(i)*Δt),(x)->gD(x,(i)*Δt),(x)->gN(x,(i)*Δt),A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:] +
              (sqrtΔt.*dW.*Minv*quadfbasis((x)->σ(x,(i-1)*Δt),(x)->gD(x,(i-1)*Δt),(x)->gN(x,(i-1)*Δt),
                          A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
  @femheat_implicitpreamble
  for i=1:numiters
    dW = next(rands)
    t += Δt
    @femheat_stochasticimplicitlinearsolve
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:linear,:ImplicitEuler,:deterministic})
  @femheat_deterministicpreamble
  K = eye(N) + Δt*Minv*D*A #D okay since numVar = 1 for linear
  lhs = K[freenode,freenode]
  rhs(u,i) = u[freenode,:] + (Minv*Δt*quadfbasis((x)->f(x,(i)*Δt),(x)->gD(x,(i)*Δt),(x)->gN(x,(i)*Δt),A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
  @femheat_implicitpreamble
  for i=1:numiters
    t += Δt
    @femheat_deterministicimplicitlinearsolve
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:linear,:CrankNicholson,:stochastic})
  @femheat_stochasticpreamble
  Km = eye(N) - Δt*Minv*D*A/2 #D okay since numVar = 1 for linear
  Kp = eye(N) + Δt*Minv*D*A/2 #D okay since numVar = 1 for linear
  lhs = Kp[freenode,freenode]
  rhs(u,i,dW) = Km[freenode,freenode]*u[freenode,:] + (Minv*Δt*quadfbasis((x)->f(x,(i-.5)*Δt),(x)->gD(x,(i-.5)*Δt),(x)->gN(x,(i-.5)*Δt),A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:] +
              (sqrtΔt.*dW.*Minv*quadfbasis((x)->σ(x,(i-1)*Δt),(x)->gD(x,(i-1)*Δt),(x)->gN(x,(i-1)*Δt),
                          A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
  @femheat_implicitpreamble
  for i=1:numiters
    dW = next(rands)
    t += Δt
    @femheat_stochasticimplicitlinearsolve
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:linear,:CrankNicholson,:deterministic})
  @femheat_deterministicpreamble
  Km = eye(N) - Δt*Minv*D*A/2 #D okay since numVar = 1 for linear
  Kp = eye(N) + Δt*Minv*D*A/2 #D okay since numVar = 1 for linear
  lhs = Kp[freenode,freenode]
  rhs(u,i) = Km[freenode,freenode]*u[freenode,:] + (Minv*Δt*quadfbasis((x)->f(x,(i-.5)*Δt),(x)->gD(x,(i-.5)*Δt),(x)->gN(x,(i-.5)*Δt),A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
  @femheat_implicitpreamble
  for i=1:numiters
    t += Δt
    @femheat_deterministicimplicitlinearsolve
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:nonlinear,:SemiImplicitEuler,:deterministic}) #Incorrect for system with different diffusions
  @femheat_deterministicpreamble
  Dinv = D.^(-1)
  K = eye(N) + Δt*Minv*A
  lhs = K[freenode,freenode]
  rhs(u,i) = u[freenode,:] + (Minv*Δt*quadfbasis((u,x)->f(u,x,(i)*Δt),(x)->gD(x,(i)*Δt),(x)->gN(x,(i)*Δt),
              A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
  @femheat_implicitpreamble
  for i=1:numiters
    t += Δt
    @femheat_deterministicimplicitlinearsolve
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:nonlinear,:SemiImplicitEuler,:stochastic}) #Incorrect for system with different diffusions
  @femheat_stochasticpreamble
  Dinv = D.^(-1)
  K = eye(N) + Δt*Minv*A
  lhs = K[freenode,freenode]
  rhs(u,i,dW) = u[freenode,:] + (Minv*Δt*quadfbasis((u,x)->f(u,x,(i)*Δt),(x)->gD(x,(i)*Δt),(x)->gN(x,(i)*Δt),
              A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:] +
              (sqrtΔt.*dW.*Minv*quadfbasis((u,x)->σ(u,x,(i-1)*Δt),(x)->gD(x,(i-1)*Δt),(x)->gN(x,(i-1)*Δt),
                          A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
  @femheat_implicitpreamble
  for i=1:numiters
    dW = next(rands)
    t += Δt
    @femheat_stochasticimplicitlinearsolve
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:nonlinear,:SemiImplicitCrankNicholson,:deterministic}) #Incorrect for system with different diffusions
  @femheat_deterministicpreamble
  Dinv = D.^(-1)
  Km = eye(N) - Δt*Minv*A/2
  Kp = eye(N) + Δt*Minv*A/2
  lhs = Kp[freenode,freenode]
  rhs(u,i) = Km[freenode,freenode]*u[freenode,:] + (Minv*Δt*quadfbasis((u,x)->f(u,x,(i-.5)*Δt),(x)->gD(x,(i-.5)*Δt),(x)->gN(x,(i-.5)*Δt),
              A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
  @femheat_implicitpreamble
  for i=1:numiters
    t += Δt
    @femheat_deterministicimplicitlinearsolve
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:nonlinear,:SemiImplicitCrankNicholson,:stochastic}) #Incorrect for system with different diffusions
  @femheat_stochasticpreamble
  Dinv = D.^(-1)
  Km = eye(N) - Δt*Minv*A/2
  Kp = eye(N) + Δt*Minv*A/2
  lhs = Kp[freenode,freenode]
  rhs(u,i,dW) = Km[freenode,freenode]*u[freenode,:] + (Minv*Δt*quadfbasis((u,x)->f(u,x,(i-.5)*Δt),(x)->gD(x,(i-.5)*Δt),(x)->gN(x,(i-.5)*Δt),
              A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:] +
              (sqrtΔt.*dW.*Minv*quadfbasis((u,x)->σ(u,x,(i-1)*Δt),(x)->gD(x,(i-1)*Δt),(x)->gN(x,(i-1)*Δt),
                          A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
  @femheat_implicitpreamble
  for i=1:numiters
    dW = next(rands)
    t += Δt
    @femheat_stochasticimplicitlinearsolve
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:nonlinear,:ImplicitEuler,:deterministic})
  @femheat_deterministicpreamble
  function rhs!(u,resid,uOld,i)
    u = reshape(u,N,numvars)
    uOld = reshape(uOld,N,numvars)
    resid = reshape(resid,N,numvars)
    resid[freenode,:] = u[freenode,:] - uOld[freenode,:] + D.*(Δt*Minv[freenode,freenode]*A[freenode,freenode]*u[freenode,:]) -
    (Minv*Δt*quadfbasis((u,x)->f(u,x,(i)*Δt),(x)->gD(x,(i)*Δt),(x)->gN(x,(i)*Δt),A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
    u = vec(u)
    resid = vec(resid)
  end
  @femheat_nonlinearsolvepreamble
  for i=1:numiters
    t += Δt
    @femheat_nonlinearsolvedeterministicloop
    @femheat_footer
  end
  u,timeseries,ts
end

function femheat_solve(integrator::FEMHeatIntegrator{:nonlinear,:ImplicitEuler,:stochastic})
  @femheat_stochasticpreamble
  function rhs!(u,resid,dW,uOld,i)
    u = reshape(u,N,numvars)
    resid = reshape(resid,N,numvars)
    resid[freenode,:] = u[freenode,:] - uOld[freenode,:] + D.*(Δt*Minv[freenode,freenode]*A[freenode,freenode]*u[freenode,:]) - (Minv*Δt*quadfbasis((u,x)->f(u,x,(i)*Δt),(x)->gD(x,(i)*Δt),(x)->gN(x,(i)*Δt),A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:] -(sqrtΔt.*dW.*Minv*quadfbasis((u,x)->σ(u,x,(i)*Δt),(x)->gD(x,(i)*Δt),(x)->gN(x,(i)*Δt),
                A,u,node,elem,area,bdnode,mid,N,dirichlet,neumann,islinear,numvars))[freenode,:]
    u = vec(u)
    resid = vec(resid)
  end
  @femheat_nonlinearsolvepreamble
  for i=1:numiters
    t += Δt
    @femheat_nonlinearsolvestochasticloop
    @femheat_footer
  end
  u,timeseries,ts
end
