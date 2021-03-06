#' Apply the spatial loess fitting on the remainder at all location for each month in parallel
#'
#' Call \code{spaloess} function on the spatial domain at each time point in parallel.
#' Every spatial domain uses the same smoothing parameters
#'
#' @param input
#'     The path of input file on HDFS. It should be by-month division with temporal fitting results.
#' @param output
#'     The path of output file on HDFS. It is by-month division but with added spatial fitted value for
#'     remainder, named Rspa.
#' @param info
#'     The RData path on HDFS which contains all station metadata
#' @param cluster_control
#'     Should be a list object generated from \code{mapreduce.control} function.
#'     The list including all necessary Rhipe parameters and also user tunable
#'     MapReduce parameters.
#' @param model_control
#'     Should be a list object generated from \code{spacetime.control} function.
#'     The list including all necessary smoothing parameters of nonparametric fitting.
#' @author
#'     Xiaosu Tong
#' @export
#' @examples
#' \dontrun{
#'     FileInput <- "/tmp/bymthse"
#'     FileOutput <- "/tmp/bymthfitse"
#'     ccontrol <- mapreduce.control(libLoc=NULL, reduceTask=0, BLK=128)
#'     mcontrol <- spacetime.control(
#'       vari="remainder", time="date", n=786432, n.p=12,
#'       s.window=13, t.window = 241, degree=2, span=0.015, Edeg=2
#'     )
#'
#'     sparfit(
#'       FileInput, FileOutput, info="/tmp/station_info.RData",
#'       model_control=mcontrol, cluster_control=ccontrol
#'     )
#' }

sparfit <- function(input, output, info, model_control=spacetime.control(), cluster_control=mapreduce.control()) {

  job <- list()
  job$map <- expression({
    lapply(seq_along(map.values), function(r) {
      if(Mlcontrol$Edeg == 2) {
        fml <- as.formula("remainder ~ lon + lat + elev2")
        dropSq <- FALSE
        condParam <- "elev2"
      } else if(Mlcontrol$Edeg == 1) {
        fml <- as.formula("remainder ~ lon + lat + elev2")
        dropSq <- "elev2"
        condParam <- "elev2"
      } else if (Mlcontrol$Edeg == 0) {
        fml <- as.formula("remainder ~ lon + lat")
        dropSq <- FALSE
        condParam <- FALSE
      }

      value <- arrange(data.frame(matrix(map.values[[r]], ncol=5, byrow=TRUE)), X4, X5)
      names(value) <- c("smoothed","seasonal","trend", Mlcontrol$time, "station.id")
      value$remainder <- with(value, smoothed - trend - seasonal)

      d_ply(
        .data = value,
        .variables = Mlcontrol$time,
        .fun = function(S) {
          S <- cbind(S, station_info[, c("lon","lat","elev")])
          S$elev2 <- log2(S$elev + 128)
          lo.fit <- spaloess( fml,
            data        = S,
            degree      = Mlcontrol$degree,
            span        = Mlcontrol$span,
            parametric  = condParam,
            drop_square = dropSq,
            family      = Mlcontrol$family,
            normalize   = FALSE,
            distance    = "Latlong",
            control     = loess.control(surface = Mlcontrol$surf, iterations = Mlcontrol$siter, cell=Mlcontrol$cell),
            napred      = FALSE,
            alltree     = match.arg(Mlcontrol$surf, c("interpolate", "direct")) == "interpolate"
          )
          S$Rspa <- lo.fit$fitted
          key <- unique(S[, Mlcontrol$time])
          #S <- subset(S, select = -c(remainder, lon, lat, elev2, elev, date))[,c(4,1,2,3,5)]
          S <- S[, c("station.id", "smoothed", "seasonal", "trend", "Rspa")]
          rownames(S) <- NULL
          rhcollect(key, S)
          NULL
      })
    })
  })
  job$parameters <- list(
    Mlcontrol = model_control,
    Clcontrol = cluster_control,
    info = info
  )
  job$shared <- c(info)
  job$setup <- expression(
    map = {
      load(strsplit(info, "/")[[1]][length(strsplit(info, "/")[[1]])])
      suppressMessages(library(plyr, lib.loc=Clcontrol$libLoc))
      library(Spaloess, lib.loc=Clcontrol$libLoc)
    }
  )
  job$mapred <- list(
    mapreduce.task.timeout = 0,
    mapreduce.job.reduces = cluster_control$reduceTask,  #cdh5
    mapreduce.map.java.opts = cluster_control$map_jvm,
    mapreduce.map.memory.mb = cluster_control$map_memory,
    dfs.blocksize = cluster_control$BLK,
    rhipe_map_bytes_read = cluster_control$map_buffer_read,
    rhipe_map_buffer_size = cluster_control$map_buffer_size,
    mapreduce.map.output.compress = TRUE,
    mapreduce.output.fileoutputformat.compress.type = "BLOCK"
  )
  job$input <- rhfmt(input, type="sequence")
  job$output <- rhfmt(output, type="sequence")
  job$mon.sec <- 10
  job$jobname <- output
  job$readback <- FALSE

  job.mr <- do.call("rhwatch", job)

  #return(job.mr[[1]]$jobid) # nolint

}
