getPreValues <- function(cache){
  V <- vcvPhylo(cache$phy, anc.nodes=FALSE)
  X <- cache$pred[,3]
  unknown <- is.na(X)
  known <- !unknown
  Vkk <- V[known, known]
  Vuu <- V[unknown, unknown]
  Vku <- V[known, unknown]
  Vuk <- V[unknown, known]
  iVkk <- solve(Vkk)
  sigmabar <- as.matrix(forceSymmetric(Vuu - Vuk%*%iVkk%*%Vku))
  cholSigmabar <- chol(sigmabar)
  mubarmat <- Vuk%*%iVkk
  return(list(V=V, X=X, unknown=unknown, known=known, Vkk=Vkk, Vuu=Vuu, Vku=Vku, Vuk=Vuk, iVkk=iVkk, sigmabar=sigmabar, mubarmat=mubarmat, cholSigmabar=cholSigmabar))
}

cMVNorm <- function(cache, pars, prevalues=pv, known=FALSE){
  X <- prevalues$X
  known <- prevalues$known
  unknown <- prevalues$unknown
  mu <- rep(pars$pred.root, cache$n)
  muk <- mu[known]
  muu <- mu[unknown]
  mubar <- t(muu + prevalues$mubarmat%*%(X[known]-muk))
  #sigmabar <- pars$pred.sig2*prevalues$sigmabar
  myChol <-sqrt(pars$pred.sig2)*prevalues$cholSigmabar
  res <- dmvn(pars$missing.pred, mu=mubar, sigma = myChol, log=TRUE, isChol=TRUE)
  return(res)
}

## Proposal function to simulate conditional draws from a multivariate normal distribution
.imputePredBM <- function(cache, pars, d, move,ct=NULL, prevalues=pv){
  #(tree, dat, sig2, plot=TRUE, ...){
  X <- prevalues$X
  Vuk <- pars$pred.sig2*prevalues$Vuk
  iVkk <- (1/pars$pred.sig2)*prevalues$iVkk
  Vku <- pars$pred.sig2*prevalues$Vku
  Vuu <- pars$pred.sig2*prevalues$Vuu
  known <- prevalues$known
  unknown <- prevalues$unknown
  mu <- rep(pars$pred.root, cache$n)
  muk <- mu[known]
  muu <- mu[unknown]
  mubar <- t(muu + Vuk%*%iVkk%*%(X[known]-muk))
  sigmabar <- Vuu - Vuk%*%iVkk%*%Vku
  res <- MASS::mvrnorm(1, mubar, sigmabar)
  pars.new <- pars
  pars.new$missing.pred <- res
  hr=Inf
  type="impute"
  return(list(pars=pars.new, hr=hr, decision = type))
}

make.monitorFn <- function(model, noMonitor=c("missing.pred", "ntheta"), integers=c("gen","k")){
  parorder <- model$parorder
  rjpars <- model$rjpars
  exclude <- which(parorder %in% noMonitor)
  if(length(exclude) > 0){
    pars2monitor <- parorder[-exclude]
  } else {pars2monitor <- parorder}
  if(length(rjpars) > 0){
    rjp <- which(pars2monitor %in% rjpars)
    pars2monitor[rjp] <- paste("r", pars2monitor[rjp], sep="")
  }
  pars2monitor <- c("gen", "lnL", "prior", pars2monitor)
  type <- rep(".2f", length(pars2monitor))
  type[which(pars2monitor %in% integers)] <- "i"
  string <- paste(paste("%-8", type, sep=""), collapse="")
  monitor.fn = function(i, lik, pr, pars, accept, accept.type, j){
    names <- pars2monitor
    #names <- c("gen", "lnL", "prior", "alpha" , "sig2", "rbeta1", "endo", "k")
    #string <- "%-8i%-8.2f%-8.2f%-8.2f%-8.2f%-8.2f%-8.2f%-8i"
    acceptratios <- tapply(accept, accept.type, mean)
    names <- c(names, names(acceptratios))
    if(j==0){
      cat(sprintf("%-7.7s", names), "\n", sep=" ")                           
    }
    cat(sprintf(string, i, lik, pr, pars$alpha, pars$sig2, pars$beta1[1], pars$endo, pars$k), sprintf("%-8.2f", acceptratios),"\n", sep="")
  }
}

getTipMap <- function(pars, cache){
  map <- bayou:::.pars2map(pars,cache)
  tipreg <- rev(map$theta)
  ntipreg <- rev(map$branch)
  #ntipreg <- names(map$theta)
  dups <- !duplicated(ntipreg) & ntipreg %in% (1:nrow(cache$edge))[cache$externalEdge]
  tipreg <- tipreg[which(dups)]
  ntipreg <- ntipreg[which(dups)]
  o <- order(cache$edge[as.numeric(ntipreg), 2])
  betaID <- tipreg[o]
}

liks <- list(
  "fixed.shift_lnMass_lnMass2.fixed_endo_lnGS.impute_lnGS"=
    function(pars, cache, X, model="Custom"){
      n <- cache$n
      X <- cache$dat
      pred <- cache$pred
      pred[is.na(pred[,3]),3] <- pars$missing.pred #$impute
      betaID <- getTipMap(pars, cache)
      ## Specify the model here
      X = X - pars$beta1[betaID]*pred[,1] - pars$beta2[betaID]*pred[,2] - pars$beta3*pred[,3]
      cache$dat <- X
      ## This part adds the endothermy parameter to the theta for Mammal and Bird branches
      dpars <- pars
      dpars$theta[dpars$t2[which(dpars$sb %in% c(841, 1703))]] <- dpars$theta[dpars$t2[which(dpars$sb %in% c(841, 1703))]]+dpars$endo
      ### The part below mostly does not change
      X.c <- bayou:::C_weightmatrix(cache, dpars)$resid
      transf.phy <- bayou:::C_transf_branch_lengths(cache, 1, X.c, pars$alpha)
      transf.phy$edge.length[cache$externalEdge] <- transf.phy$edge[cache$externalEdge] + cache$SE[cache$phy$edge[cache$externalEdge, 2]]^2*(2*pars$alpha)/pars$sig2
      comp <- bayou:::C_threepoint(list(n=n, N=cache$N, anc=cache$phy$edge[, 1], des=cache$phy$edge[, 2], diagMatrix=transf.phy$diagMatrix, P=X.c, root=transf.phy$root.edge, len=transf.phy$edge.length))
      if(pars$alpha==0){
        inv.yVy <- comp$PP
        detV <- comp$logd
      } else {
        inv.yVy <- comp$PP*(2*pars$alpha)/(pars$sig2)
        detV <- comp$logd+n*log(pars$sig2/(2*pars$alpha))
      }
      llh <- -0.5*(n*log(2*pi)+detV+inv.yVy)
      llh <- llh + gs.lik(c(pars$pred.sig2, pars$pred.root), root=ROOT.GIVEN) #$impute
      return(list(loglik=llh, theta=pars$theta,resid=X.c, comp=comp, transf.phy=transf.phy))
    },
  "rj.shift_lnMass.fixed_endo.missing_drop"=
    function(pars, cache, X, model="Custom"){
      n <- cache$n
      X <- cache$dat
      pred <- cache$pred
      #pred[is.na(pred[,3]),3] <- pars$missing.pred #$impute
      betaID <- getTipMap(pars, cache)
      ## Specify the model here
      X = X - pars$beta1[betaID]*pred[,1]# - pars$beta2[betaID]*pred[,2] - pars$beta3*pred[,3]
      cache$dat <- X
      ## This part adds the endothermy parameter to the theta for Mammal and Bird branches
      dpars <- pars
      dpars$theta[dpars$t2[which(dpars$sb %in% c(841, 1703))]] <- dpars$theta[dpars$t2[which(dpars$sb %in% c(841, 1703))]]+dpars$endo
      ### The part below mostly does not change
      X.c <- bayou:::C_weightmatrix(cache, dpars)$resid
      transf.phy <- bayou:::C_transf_branch_lengths(cache, 1, X.c, pars$alpha)
      transf.phy$edge.length[cache$externalEdge] <- transf.phy$edge[cache$externalEdge] + cache$SE[cache$phy$edge[cache$externalEdge, 2]]^2*(2*pars$alpha)/pars$sig2
      comp <- bayou:::C_threepoint(list(n=n, N=cache$N, anc=cache$phy$edge[, 1], des=cache$phy$edge[, 2], diagMatrix=transf.phy$diagMatrix, P=X.c, root=transf.phy$root.edge, len=transf.phy$edge.length))
      if(pars$alpha==0){
        inv.yVy <- comp$PP
        detV <- comp$logd
      } else {
        inv.yVy <- comp$PP*(2*pars$alpha)/(pars$sig2)
        detV <- comp$logd+n*log(pars$sig2/(2*pars$alpha))
      }
      llh <- -0.5*(n*log(2*pi)+detV+inv.yVy)
      #llh <- llh + gs.lik(c(pars$pred.sig2, pars$pred.root), root=ROOT.GIVEN) #$impute
      return(list(loglik=llh, theta=pars$theta,resid=X.c, comp=comp, transf.phy=transf.phy))
    },
  "rj.shift_lnMass.fixed_endo.impute_TempQ10"
  )

startpars <- list(
  "fixed.shift_lnMass_lnMass2.fixed_endo_lnGS.impute_lnGS"=
    function(sb, k) {
      k <- length(sb)
      startpar <- list(alpha=0.1, sig2=3, beta1=rnorm(k+1, 0.7, 0.1), beta2=rnorm(k+1, 0, 0.01), beta3=rnorm(1, 0, 0.05), endo=2, k=k, ntheta=k+1, theta=rnorm(k+1, 0, 1), sb=sb, loc=rep(0, k), t2=2:(k+1))
      return(startpar)
    },
  "rj.shift_lnMass.fixed_endo.missing_drop"=
    function(sb, k) {
      sb <- sample(1:length(cache$bdesc), k, replace=FALSE, prob = sapply(cache$bdesc, length))
      startpar <- list(alpha=0.1, sig2=3, beta1=rnorm(k+1, 0.7, 0.1), endo=2, k=k, ntheta=k+1, theta=rnorm(k+1, 0, 1), sb=sb, loc=rep(0, k), t2=2:(k+1))
      return(startpar)
    }
)
monitors <- list(
  "fixed.shift_lnMass_lnMass2.fixed_endo_lnGS.impute_lnGS"=
    function(i, lik, pr, pars, accept, accept.type, j){
      names <- c("gen", "lnL", "prior", "alpha","sig2", "rbeta1", "endo", "k")
      string <- "%-8i%-8.2f%-8.2f%-8.2f%-8.2f%-8.2f%-8.2f%-8i"
      acceptratios <- tapply(accept, accept.type, mean)
      names <- c(names, names(acceptratios))
      if(j==0){
        cat(sprintf("%-7.7s", names), "\n", sep=" ")                           
      }
      cat(sprintf(string, i, lik, pr, pars$alpha, pars$sig2, pars$beta1[1], pars$endo, pars$k), sprintf("%-8.2f", acceptratios),"\n", sep="")
    },
  "rj.shift_lnMass.fixed_endo.missing_drop"=
    function(i, lik, pr, pars, accept, accept.type, j){
      names <- c("gen", "lnL", "prior", "alpha","sig2", "rbeta1", "endo", "k")
      string <- "%-8i%-8.2f%-8.2f%-8.2f%-8.2f%-8.2f%-8.2f%-8i"
      acceptratios <- tapply(accept, accept.type, mean)
      names <- c(names, names(acceptratios))
      if(j==0){
        cat(sprintf("%-7.7s", names), "\n", sep=" ")                           
      }
      cat(sprintf(string, i, lik, pr, pars$alpha, pars$sig2, pars$beta1[1], pars$endo, pars$k), sprintf("%-8.2f", acceptratios),"\n", sep="")
    }
  )

models <- list(
  "fixed.shift_lnMass_lnMass2.fixed_endo_lnGS.impute_lnGS"=
    function(startpar, monitor, lik){
      list(moves = list(alpha=".multiplierProposal", sig2=".multiplierProposal", 
                        beta1=".vectorMultiplier", beta2=".vectorSlidingWindow",
                        beta3=".slidingWindowProposal", endo=".slidingWindowProposal", 
                        theta=".adjustTheta", slide=".slide", 
                        pred.sig2=".multiplierProposal" , pred.root=".slidingWindowProposal", #$impute 
                        missing.pred=".imputePredBM" #$impute
      ),
      control.weights = list(alpha=4, sig2=2, beta1=10, 
                             beta2=8, beta3=4, endo=3, 
                             theta=10, slide=2, k=0,
                             pred.sig2=1, pred.root=1, missing.pred=3 #$impute
      ),
      D = list(alpha=1, sig2= 0.75, beta1=0.75, beta2=0.05, beta3=0.05, endo=0.25, theta=2, slide=1, 
               pred.sig2=1, pred.root=1, missing.pred=1 #$impute
      ),
      parorder = names(startpar),
      rjpars = c("theta"),
      shiftpars = c("sb", "loc", "t2"),
      monitor.fn = monitor,
      lik.fn = lik)
    },
  "rj.shift_lnMass.fixed_endo.missing_drop"=
    function(startpar, monitor, lik){
      list(moves = list(alpha=".multiplierProposal", sig2=".multiplierProposal", 
                        beta1=".vectorMultiplier", endo=".slidingWindowProposal", 
                        k=".splitmergebd", theta=".adjustTheta", slide=".slide"                       
      ),
      control.weights = list(alpha=4, sig2=2, beta1=5, 
                             endo=3,  k=10, theta=5, slide=2
      ),
      D = list(alpha=1, sig2= 0.75, beta1=0.75, k=c(1,1), endo=0.25, theta=2, slide=1
      ),
      parorder = names(startpar),
      rjpars = c("theta", "beta1"),
      shiftpars = c("sb", "loc", "t2"),
      monitor.fn = monitor,
      lik.fn = lik)
    }
  )


#priors <- list(
#  "fixed.shift_lnMass_lnMass2.fixed_endo_lnGS.impute_lnGS"=
#    make.prior(tree, plot.prior = FALSE, 
#               dists=list(dalpha="dhalfcauchy", dsig2="dhalfcauchy", dbeta1="dnorm",
#                          dbeta2="dnorm", dbeta3="dnorm", dendo="dnorm", 
#                          dsb="fixed", dk="fixed", dtheta="dnorm",
#                          dpred.sig2="dhalfcauchy", dpred.root="dnorm" #$impute
#               ), 
#               param=list(dalpha=list(scale=1), dsig2=list(scale=1), dbeta1=list(mean=0.7, sd=0.1), 
#                          dbeta2=list(mean=0, sd=0.05),dbeta3=list(mean=0, sd=0.05), 
#                          dendo=list(mean=0, sd=4),  dk="fixed", dsb="fixed", 
#                          dtheta=list(mean=0, sd=4),
#                          dpred.sig2=list(scale=1), dpred.root=list(mean=1, sd=1) #$impute
#               ), 
#               fixed=list(sb=startpar$sb, k=startpar$k)
#    ),
#  "rj.shift_lnMass.fixed_endo.missing_drop"=
#    make.prior(tree, plot.prior = FALSE, 
#               dists=list(dalpha="dhalfcauchy", dsig2="dhalfcauchy", dbeta1="dnorm",
#                          dendo="dnorm", dsb="dsb", dk="cdpois", dtheta="dnorm"
#                ), 
#               param=list(dalpha=list(scale=1), dsig2=list(scale=1), 
#                          dbeta1=list(mean=0.7, sd=0.1), dendo=list(mean=0, sd=4),
#                          dk=list(lambda=50, kmax=500), dsb=list(bmax=1,prob=1), 
#                          dtheta=list(mean=0, sd=2.5)
#               ), 
#               model="ffancova"
#    )
#  )


colorRamp <- function(trait, pal, nn){
  strait <- (trait-min(trait))/max(trait-min(trait))
  itrait <- round(strait*nn, 0)+1
  return(pal(nn+1)[itrait])
}
addColorBar <- function(x, y, height, width, pal, trait, ticks, adjx=0, n=100,cex.lab=1,pos=2, text.col="black"){
  legend_image <- as.raster(matrix(rev(pal(n)),ncol = 1))
  #text(x = 1.5, y = round(seq(range(ave.Div)[1], range(ave.Div)[2], l = 5), 2), labels = seq(range(ave.Div)[1], range(ave.Div)[2], l = 5))
  seqtrait <- seq(min(trait), max(trait), length.out=nrow(legend_image))
  mincut <- n-which(abs(seqtrait - min(ticks))==min(abs(seqtrait-min(ticks))))
  maxcut <- n-which(abs(seqtrait - max(ticks))==min(abs(seqtrait-max(ticks))))
  legend_cut <- legend_image[maxcut:mincut,]
  legend_cut <- rbind(matrix(rep(legend_image[1,1],round(0.05*n,0)),ncol=1), legend_cut)
  rasterImage(legend_cut, x, y, x+width, y+height)
  ticklab <- format(ticks, digits=2, trim=TRUE)
  ticklab[length(ticklab)] <- paste(">", ticklab[length(ticklab)], sep="")
  text(x+adjx, y=seq(y, y+height, length.out=length(ticks)), labels=ticklab, pos=pos,cex=cex.lab, col=text.col)
}

plotBranchHeatMap <- function(tree, chain, variable, burnin=0, nn=NULL, pal, legend_ticks, ...){
  seq1 <- floor(max(seq(burnin*length(chain$gen),1), length(chain$gen), 1))
  if(is.null(nn)) nn <- length(seq1) else { seq1 <- floor(seq(max(burnin*length(chain$gen),1), length(chain$gen), length.out=nn))}
  if(length(nn) > length(chain$gen)) stop("Number of samples greater than chain length, lower nn")
  abranches <- lapply(1:nrow(tree$edge), .ancestorBranches, cache=cache)
  allbranches <- sapply(1:nrow(tree$edge), function(x) .branchRegime(x, abranches, chain, variable, seq1, summary=TRUE))
  plot(tree, edge.color=colorRamp(allbranches, pal, 100), ...)
  addColorBar(x=470, y=100, height=150, width=10, pal=pal, n=100, trait=allbranches, ticks=legend_ticks,adjx=25, cex.lab=.5, text.col="white")
}


.ancestorBranches <- function(branch, cache){
  ancbranches <- which(sapply(cache$bdesc, function(x) branch %in% x))
  sort(ancbranches, decreasing=FALSE)
}
.branchRegime <- function(branch, abranches, chain, parameter, seqx, summary=FALSE){
  ancs <- c(branch, abranches[[branch]])
  ancshifts <- lapply(1:length(seqx), function(x) chain$t2[[seqx[x]]][which(chain$sb[[seqx[x]]] == ancs[min(which(ancs %in% chain$sb[[seqx[x]]]))])])
  ancshifts <- sapply(ancshifts, function(x) ifelse(length(x)==0, 1, x))
  ests <- sapply(1:length(ancshifts), function(x) chain[[parameter]][[seqx[x]]][ancshifts[x]])
  res <- cbind(ests)
  if(summary){
    return(apply(res, 2, median))
  } else {
    return(res)
  }
}

makeBayouModel <- function(f, rjpars, cache, prior, impute=NULL, startpar=NULL, moves=NULL, control.weights=NULL, D=NULL, shiftpars=c("sb", "loc", "t2")){
  vars <- terms(f)
  cache$pred <- as.data.frame(cache$pred)
  dep <-  rownames(attr(vars, "factors"))[attr(vars, "response")]
  mf <- cbind(cache$dat, cache$pred)
  colnames(mf)[1] <- dep
  MF <- model.frame(f, data=mf, na.action=na.pass)
  MM <- model.matrix(f, MF)
  colnames(MM) <- gsub(":", "x", colnames(MM))
  parnames <- paste("beta", colnames(MM)[-1], sep="_")
  if(length(rjpars) > 0){
    rjpars2 <- c(rjpars, paste("beta", rjpars, sep="_"))
    rj <- which(colnames(MM) %in% rjpars2)-1
    expFn <- function(pars, cache){
      betaID <- getTipMap(pars, cache)    
      if(length(impute)>0){
        MF[is.na(MF[,impute]),impute] <- pars$missing.pred #$impute
        MM <- model.matrix(f, MF)
      }
      parframe <- lapply(pars[parnames], function(x) return(x))
      parframe[rj] <- lapply(parframe[rj], function(x) x[betaID])
      ExpV <- apply(sapply(1:length(parframe), function(x) parframe[[x]]*MM[,x+1]), 1, sum)
      return(ExpV)
    }
  } else {
    rjpars2 <- numeric(0)
    expFn <- function(pars, cache){
      #betaID <- getTipMap(pars, cache)
      if(length(impute)>0){
        MF[is.na(MF[,impute]),impute] <- pars$missing.pred #$impute
        MM <- model.matrix(f, MF)
      }
      parframe <- lapply(pars[parnames], function(x) return(x))
      #parframe[rjpars] <- lapply(parframe[rjpars], function(x) x[betaID])
      ExpV <- apply(sapply(1:length(parframe), function(x) parframe[[x]]*MM[,x+1]), 1, sum)
      return(ExpV)
    }
  }
  likFn <- function(pars, cache, X, model="Custom"){
    n <- cache$n
    X <- cache$dat
    pred <- cache$pred
    ## Specify the model here
    X = X - expFn(pars, cache)
    cache$dat <- X
    ### The part below mostly does not change
    X.c <- bayou:::C_weightmatrix(cache, pars)$resid
    transf.phy <- bayou:::C_transf_branch_lengths(cache, 1, X.c, pars$alpha)
    transf.phy$edge.length[cache$externalEdge] <- transf.phy$edge[cache$externalEdge] + cache$SE[cache$phy$edge[cache$externalEdge, 2]]^2*(2*pars$alpha)/pars$sig2
    comp <- bayou:::C_threepoint(list(n=n, N=cache$N, anc=cache$phy$edge[, 1], des=cache$phy$edge[, 2], diagMatrix=transf.phy$diagMatrix, P=X.c, root=transf.phy$root.edge, len=transf.phy$edge.length))
    if(pars$alpha==0){
      inv.yVy <- comp$PP
      detV <- comp$logd
    } else {
      inv.yVy <- comp$PP*(2*pars$alpha)/(pars$sig2)
      detV <- comp$logd+n*log(pars$sig2/(2*pars$alpha))
    }
    llh <- -0.5*(n*log(2*pi)+detV+inv.yVy)
    return(list(loglik=llh, theta=pars$theta,resid=X.c, comp=comp, transf.phy=transf.phy))
  }
  monitorFn <- function(i, lik, pr, pars, accept, accept.type, j){
    names <- c("gen", "lnL", "prior", "alpha","sig2", parnames, "rtheta", "k")
    format <- c("%-8i",rep("%-8.2f",4), rep("%-8.2f", length(parnames)), "%-8.2f","%-8i")
    acceptratios <- tapply(accept, accept.type, mean)
    names <- c(names, names(acceptratios))
    if(j==0){
      cat(sprintf("%-7.7s", names), "\n", sep=" ")                           
    }
    item <- c(i, lik, pr, pars$alpha, pars$sig2, sapply(pars[parnames], function(x) x[1]), pars$theta[1], pars$k)
    cat(sapply(1:length(item), function(x) sprintf(format[x], item[x])), sprintf("%-8.2f", acceptratios),"\n", sep="")
  }
  rdists <- getSimDists(prior)
  ## Set default moves if not specified. 
  if(length(rjpars) > 0){
    if(is.null(moves)){
      moves =  c(list(alpha=".multiplierProposal", sig2=".multiplierProposal"), 
                 as.list(setNames(rep(".vectorSlidingWindow", length(parnames)), parnames)),
                 c(theta=".adjustTheta", k=".splitmergebd", slide=".slide"))
    }
    if(is.null(control.weights)){
      control.weights <- setNames(rep(1, length(parnames)+5), c("alpha", "sig2", parnames, "k", "theta", "slide"))
      control.weights[c("alpha", parnames)] <- 2
      control.weights[c("theta", parnames[rj])] <- 10
      control.weights["k"] <- 5
      control.weights <- as.list(control.weights)
    }
    
    if(is.null(D)){
      D <- lapply(rdists[!(names(rdists) %in% shiftpars)], function(x) sd(x(1000))/50)
      D$k <- rep(1, length(rjpars))
      D$slide <- 1
    }
    {
      parorder <- c("alpha", "sig2", parnames,"theta", "k","ntheta")
      rjord <- which(parorder %in% rjpars2)
      fixed <- names(attributes(prior)$fixed)
      if(length(rjord > 0)){
        parorder <- c(parorder[-rjord], fixed , parorder[rjord])
      } else {
        parorder <- c(parorder, fixed)
      }
      parorder <- parorder[!duplicated(parorder) & !(parorder %in% shiftpars)]
      
    }
    if(is.null(startpar)){
      simdists <- rdists[parorder[!(parorder %in% c(rjpars2,shiftpars, "ntheta"))]]
      if(length(attributes(prior)$fixed)>0){
        simdists[names(attributes(prior)$fixed)] <- lapply(1:length(attributes(prior)$fixed), function(x) function(n) attributes(prior)$fixed[[x]])
        fixed.pars <- attributes(prior)$fixed
        fixed <- TRUE
      } else {fixed <- FALSE}
      simdists <- simdists[!is.na(names(simdists))]
      startpar <- lapply(simdists, function(x) x(1))
      startpar$ntheta <- startpar$k+1
      startpar[parorder[(parorder %in% c(rjpars2))]] <- lapply(rdists[parorder[(parorder %in% c(rjpars2))]], function(x) x(startpar$ntheta))
      startpar <- c(startpar, list(sb=sample(1:length(cache$bdesc), startpar$k, replace=FALSE, prob = sapply(cache$bdesc, length)), loc=rep(0, startpar$k), t2=2:startpar$ntheta))
      startpar <- startpar[c(parorder, shiftpars)]
    }
  } else {
    rj <- numeric(0)
    if(is.null(moves)){
      moves =  c(list(alpha=".multiplierProposal", sig2=".multiplierProposal"), 
                 as.list(setNames(rep(".slidingWindowProposal", length(parnames)), parnames)),
                 c(theta=".adjustTheta"))
    }
    if(is.null(control.weights)){
      control.weights <- setNames(rep(1, length(parnames)+5), c("alpha", "sig2", parnames, "k", "theta", "slide"))
      control.weights[c("alpha", parnames)] <- 2
      control.weights[c("theta", parnames[rj])] <- 6
      control.weights[c("k","slide")] <- 0
      control.weights <- as.list(control.weights)
    }
    if(is.null(D)){
        D <- lapply(rdists[!(names(rdists) %in% shiftpars)], function(x) sd(x(1000))/50)
        D$k <- 1
        D$slide <- 1
      }
    {
        parorder <- c("alpha", "sig2", parnames,"theta", "k","ntheta")
        rjord <- which(parorder %in% rjpars2)
        fixed <- names(attributes(prior)$fixed)
        if(length(rjord > 0)){
          parorder <- c(parorder[-rjord], fixed , parorder[rjord])
        } else {
          parorder <- c(parorder, fixed)
        }
        parorder <- parorder[!duplicated(parorder) & !(parorder %in% shiftpars)]
    }
    if(is.null(startpar)){
        simdists <- rdists[parorder[!(parorder %in% c(rjpars2,shiftpars, "ntheta"))]]
        if(length(attributes(prior)$fixed)>0){
          simdists[names(attributes(prior)$fixed)] <- lapply(1:length(attributes(prior)$fixed), function(x) function(n) attributes(prior)$fixed[[x]])
          fixed.pars <- attributes(prior)$fixed
        } 
        simdists <- simdists[!is.na(names(simdists))]
        startpar <- lapply(simdists, function(x) x(1))
        if(!("k" %in% fixed)){
          startpar$k <- 0
          startpar$ntheta <- startpar$k+1
          if(startpar$k==0) startpar$t2 <- numeric(0) else startpar$t2 <- 2:(startpar$ntheta) 
        } else {
          startpar$ntheta <- startpar$k+1
          startpar$t2 <- 2:(startpar$ntheta)
        }
        startpar <- startpar[c(parorder, shiftpars)]
        #startpar[parorder[(parorder %in% c(rjpars2))]] <- lapply(rdists[parorder[(parorder %in% c(rjpars2))]], function(x) x(startpar$ntheta))
        #startpar <- c(startpar, list(sb=numeric(0), loc=numeric(0), t2=numeric(0)))
      }
    }
  rjpars[!(rjpars %in% "theta")] <- paste("beta",rjpars[!(rjpars %in% "theta")], sep="_")
  model <- list(moves=moves, control.weights=control.weights, D=D, rjpars=rjpars, parorder=parorder, shiftpars=shiftpars, monitor.fn=monitorFn, lik.fn=likFn)
  if(length(impute)>0){
    missing <- which(is.na(cache$pred[,impute])) #$impute
    pv <- getPreValues(cache) #$impute
    model$moves$missing.pred <- ".imputePredBM"
    model$control.weights$missing.pred <- 1
    model$D$missing.pred <- 1
    startpar <- .imputePredBM(cache, startpar, d=1, NULL, ct=NULL, prevalues=pv)$pars#$impute 
    bp <- which(names(startpar)=="pred.root")
    model$parorder <- c(parorder[1:bp], "missing.pred", if(length(parorder)>bp)parorder[(bp+1):length(parorder)] else NULL)
    startpar <- startpar[c(parorder, names(startpar)[!names(startpar) %in% parorder])]
  }
  
  #try(prior(startpar))
  #try(likFn(startpar, cache, cache$dat))
  return(list(model=model, startpar=startpar))
}

getSimDists <- function(prior){
  dists <- attributes(prior)$dist
  fixed <- which(attributes(prior)$dist=="fixed")
  notfixed <- which(attributes(prior)$dist!="fixed")
  dists <- dists[notfixed]
  prior.params <- attributes(prior)$param
  rdists <- lapply(dists,function(x) gsub('^[a-zA-Z]',"r",x))
  prior.params <- lapply(prior.params,function(x) x[-which(names(x)=="log")])
  rdists.fx <- lapply(rdists,get)
  rdists.fx <- lapply(1:length(rdists.fx),function(x) bayou:::.set.defaults(rdists.fx[[x]],defaults=prior.params[[x]]))
  names(rdists.fx) <- gsub('^[a-zA-Z]',"",names(rdists))
  return(rdists.fx)
}