


#' Transform RNA-Seq Data Ready for Linear Mixed Modelling with dream()
#'
#' Transform count data to log2-counts per million (logCPM), estimate the mean-variance relationship and use this to compute appropriate observation-level weights. The data are then ready for linear mixed modelling with dream().   This method is the same as limma::voom(), except that it allows random effects in the formula
#'
#' @param counts a numeric 'matrix' containing raw counts, or an 'ExpressionSet' containing raw counts, or a 'DGEList' object. Counts must be non-negative and NAs are not permitted.
#' @param formula specifies variables for the linear (mixed) model.  Must only specify covariates, since the rows of exprObj are automatically used a a response. e.g.: ~ a + b + (1|c)  Formulas with only fixed effects also work, and lmFit() followed by contrasts.fit() are run.
#' @param data data.frame with columns corresponding to formula 
#' @param lib.size numeric vector containing total library sizes for each sample.  Defaults to the normalized (effective) library sizes in 'counts' if 'counts' is a 'DGEList' or to the columnwise count totals if 'counts' is a matrix.
#' @param normalize.method the microarray-style normalization method to be applied to the logCPM values (if any).  Choices are as for the 'method' argument of 'normalizeBetweenArrays' when the data is single-channel.  Any normalization factors found in 'counts' will still be used even if 'normalize.method'="none".
#' @param span width of the lowess smoothing window as a proportion.
#' @param plot logical, should a plot of the mean-variance trend be displayed?
#' @param save.plot logical, should the coordinates and line of the plot be saved in the output?
#' @param quiet suppress message, default FALSE
#' @param BPPARAM parameters for parallel evaluation
#' @param      ... other arguments are passed to 'lmer'.
#'
#' @return
#' An 'EList' object just like the result of limma::voom()
#'
#' @details Adapted from vomm() in limma v3.40.2
#' @seealso limma::voom()
#' @examples
#' # library(variancePartition)
#' library(edgeR)
#' library(BiocParallel)
#' 
#' data(varPartDEdata)
#' 
#' # normalize RNA-seq counts
#' dge = DGEList(counts = countMatrix)
#' dge = calcNormFactors(dge)
#' 
#' # specify formula with random effect for Individual
#' form <- ~ Disease + (1|Individual) 
#' 
#' # compute observation weights
#' vobj = voomWithDreamWeights( dge[1:20,], form, metadata)
#' 
#' # fit dream model 
#' res = dream( vobj, form, metadata)
#' 
#' # extract results
#' topTable(res, coef="Disease1")
#' 
# # Parallel processing using multiple cores with reduced memory usage
# param = SnowParam(4, "SOCK", progressbar=TRUE)
# vobj = voomWithDreamWeights( dge[1:20,], form, metadata, BPPARAM=param)
#' 
#' @importFrom lme4 VarCorr 
#' @importFrom stats approxfun predict
#' @export
voomWithDreamWeights <- function(counts, formula, data, lib.size=NULL, normalize.method="none", span=0.5, plot=FALSE, save.plot=FALSE, quiet=FALSE, BPPARAM=bpparam(),...){

	out <- list()

	#	Check counts
	if(is(counts,"DGEList")) {
		out$genes <- counts$genes
		out$targets <- counts$samples
		if(is.null(design) && diff(range(as.numeric(counts$sample$group)))>0) design <- model.matrix(~group,data=counts$samples)
		if(is.null(lib.size)) lib.size <- counts$samples$lib.size*counts$samples$norm.factors
		counts <- counts$counts
	} else {
		isExpressionSet <- suppressPackageStartupMessages(is(counts,"ExpressionSet"))
		if(isExpressionSet) {
			if(length(Biobase::fData(counts))) out$genes <- Biobase::fData(counts)
			if(length(Biobase::pData(counts))) out$targets <- Biobase::pData(counts)
			counts <- Biobase::exprs(counts)
		} else {
			counts <- as.matrix(counts)
		}
	}

	n <- nrow(counts)
	if(n < 2L) stop("Need at least two genes to fit a mean-variance trend")

	# #	Check design
	# if(is.null(design)) {
	# 	design <- matrix(1,ncol(counts),1)
	# 	rownames(design) <- colnames(counts)
	# 	colnames(design) <- "GrandMean"
	# }

	# Check lib.size
	if(is.null(lib.size)) lib.size <- colSums(counts)

	#	Fit linear model to log2-counts-per-million
	y <- t(log2(t(counts+0.5)/(lib.size+1)*1e6))
	y <- normalizeBetweenArrays(y,method=normalize.method)
	
	# Fit regression model
	#---------------------

	if( .isMixedModelFormula( formula, data) ){

		if( missing(data) ){
			stop("Must specify argument 'data'\n")
		}
		# fit linear mixed model
		vpList = fitVarPartModel( y, formula, data, showWarnings=FALSE, ...,fxn = function(fit){
			# extract 
			# 1) sqrt residual variance (i.e. residual standard deviation)
			# 2) fitted values
			list( sd = attr(VarCorr(fit), 'sc'),
				fitted.values = predict(fit) )
			}, BPPARAM=BPPARAM )

		fit = list()
		fit$sigma <- sapply( vpList, function(x) x$sd)	
		fit$df.residual = rep(2, length(fit$sigma)) # check this

		# extract fitted values
		fitted.values <- lapply( vpList, function(x) x$fitted.values)
		fitted.values <- do.call("rbind", fitted.values )
	}else{

		if( ! quiet) message("Fixed effect model, using limma directly...")

		design = model.matrix(formula, data)
		fit <- lmFit(y,design,...)

		if(fit$rank < ncol(design)) {
			j <- fit$pivot[1:fit$rank]
			fitted.values <- fit$coef[,j,drop=FALSE] %*% t(fit$design[,j,drop=FALSE])
		} else {
			fitted.values <- fit$coef %*% t(fit$design)
		}
	}

	if(is.null(fit$Amean)) fit$Amean <- rowMeans(y,na.rm=TRUE)

	#		If no replication found, set all weight to 1
	NWithReps <- sum(fit$df.residual > 0L)
	if(NWithReps < 2L) {
		if(NWithReps == 0L) warning("The experimental design has no replication. Setting weights to 1.")
		if(NWithReps == 1L) warning("Only one gene with any replication. Setting weights to 1.")
		out$E <- y
		out$weights <- y
		out$weights[] <- 1
		if( !is.null(design) ) out$design <- design
		if(is.null(out$targets))
			out$targets <- data.frame(lib.size=lib.size)
		else
			out$targets$lib.size <- lib.size
		return(new("EList",out))
	}

	# Fit lowess trend to sqrt-standard-deviations by log-count-size
	sx <- fit$Amean+mean(log2(lib.size+1))-log2(1e6)
	
	# get residual standard deviation
	if( is(fit, "MArrayLM2") ){
		# fit is result of dream()
		sy <- sqrt(attr(fit, "varComp")$resid)
	}else{
		# fit is result of lmFit()
		sy <- sqrt(fit$sigma)
	}

	allzero <- rowSums(counts)==0
	if(any(allzero)) {
		sx <- sx[!allzero]
		sy <- sy[!allzero]
	}
	l <- stats::lowess(sx,sy,f=span)
	if(plot) {
		plot(sx,sy,xlab="log2( count size + 0.5 )",ylab="Sqrt( standard deviation )",pch=16,cex=0.25)
		title("voom: Mean-variance trend")
		lines(l,col="red")
	}

	#	Make interpolating rule
	#	Special treatment of zero counts is now removed;
	#	instead zero counts get same variance as smallest gene average.
	#	l$x <- c(0.5^0.25, l$x)
	#	l$x <- c(log2(0.5), l$x)
	#	var0 <- var(log2(0.5*1e6/(lib.size+0.5)))^0.25
	#	var0 <- max(var0,1e-6)
	#	l$y <- c(var0, l$y)
	f <- approxfun(l, rule=2)

	fitted.cpm <- 2^fitted.values
	fitted.count <- 1e-6 * t(t(fitted.cpm)*(lib.size+1))
	fitted.logcount <- log2(fitted.count)

	#	Apply trend to individual observations
	w <- 1/f(fitted.logcount)^4
	dim(w) <- dim(fitted.logcount)

	#	Output
	out$E <- y
	out$weights <- w
	if( !is.null(design) ) out$design <- design
	if(is.null(out$targets))
		out$targets <- data.frame(lib.size=lib.size)
	else
		out$targets$lib.size <- lib.size
	if(save.plot) {
		out$voom.xy <- list(x=sx,y=sy,xlab="log2( count size + 0.5 )",ylab="Sqrt( standard deviation )")
		out$voom.line <- l
	}

	new("EList",out)
}