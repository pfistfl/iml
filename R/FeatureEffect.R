# Feature Effect ---------------------------------------------------------------

#' @title Effect of a feature on predictions
#'
#' @description `FeatureEffect` computes and plots (individual) feature effects
#'   of prediction models.
#'
#' @importFrom data.table melt setkeyv
#' @import ggplot2
#' @importFrom stats cmdscale ecdf quantile
#'
#' @details
#'
#' The [FeatureEffect] class compute the effect a feature has on the prediction.
#' Different methods are implemented:
#' - Accumulated Local Effect (ALE) plots
#' - Partial Dependence Plots (PDPs)
#' - Individual Conditional Expectation (ICE) curves
#'
#' Accumulated local effects and partial dependence plots both show the average
#' model prediction over the feature. The difference is that ALE are computed as
#' accumulated differences over the conditional distribution and partial
#' dependence plots over the marginal distribution. ALE plots preferable to
#' PDPs, because they are faster and unbiased when features are correlated.
#'
#' ALE plots for categorical features are automatically ordered by the
#' similarity of the categories based on the distribution of the other features
#' for instances in a category. When the feature is an ordered factor, the ALE
#' plot leaves the order as is.
#'
#' Individual conditional expectation curves describe how, for a single
#' observation, the prediction changes when the feature changes and can be
#' combined with partial dependence plots.
#'
#' To learn more about accumulated local effects, read the [Interpretable Machine
#' Learning book](https://christophm.github.io/interpretable-ml-book/ale.html).
#'
#' For the partial dependence plots:
#' \url{https://christophm.github.io/interpretable-ml-book/pdp.html}
#'
#' For individual conditional expectation:
#' \url{https://christophm.github.io/interpretable-ml-book/ice.html}
#'
#' @references
#' Apley, D. W. 2016. "Visualizing the Effects of Predictor Variables in Black
#' Box Supervised Learning Models." ArXiv Preprint.
#'
#' Friedman, J.H. 2001. "Greedy Function Approximation: A Gradient Boosting
#' Machine." Annals of Statistics 29: 1189-1232.
#'
#' Goldstein, A., Kapelner, A., Bleich, J., and Pitkin, E. (2013). Peeking
#' Inside the Black Box: Visualizing Statistical Learning with Plots of
#' Individual Conditional Expectation, 1-22.
#' https://doi.org/10.1080/10618600.2014.907095

#' @export
#' @examples
#' # We train a random forest on the Boston dataset:
#' data("Boston", package = "MASS")
#' library("randomForest")
#' rf <- randomForest(medv ~ ., data = Boston, ntree = 50)
#' mod <- Predictor$new(rf, data = Boston)
#'
#' # Compute the accumulated local effects for the first feature
#' eff <- FeatureEffect$new(mod, feature = "rm", grid.size = 30)
#' eff$plot()
#'
#' # Again, but this time with a partial dependence plot and ice curves
#' eff <- FeatureEffect$new(mod,
#'   feature = "rm", method = "pdp+ice",
#'   grid.size = 30
#' )
#' plot(eff)
#'
#' # Since the result is a ggplot object, you can extend it:
#' library("ggplot2")
#' plot(eff) +
#'   # Adds a title
#'   ggtitle("Partial dependence") +
#'   # Adds original predictions
#'   geom_point(
#'     data = Boston, aes(y = mod$predict(Boston)[[1]], x = rm),
#'     color = "pink", size = 0.5
#'   )
#'
#' # If you want to do your own thing, just extract the data:
#' eff.dat <- eff$results
#' head(eff.dat)
#'
#' # You can also use the object to "predict" the marginal values.
#' eff$predict(Boston[1:3, ])
#' # Instead of the entire data.frame, you can also use feature values:
#' eff$predict(c(5, 6, 7))
#'
#' # You can reuse the pdp object for other features:
#' eff$set.feature("lstat")
#' plot(eff)
#'
#' # Only plotting the aggregated partial dependence:
#' eff <- FeatureEffect$new(mod, feature = "crim", method = "pdp")
#' eff$plot()
#'
#' # Only plotting the individual conditional expectation:
#' eff <- FeatureEffect$new(mod, feature = "crim", method = "ice")
#' eff$plot()
#'
#' # Accumulated local effects and partial dependence plots support up to two
#' # features:
#' eff <- FeatureEffect$new(mod, feature = c("crim", "lstat"))
#' plot(eff)
#'
#' # FeatureEffect plots also works with multiclass classification
#' rf <- randomForest(Species ~ ., data = iris, ntree = 50)
#' mod <- Predictor$new(rf, data = iris, type = "prob")
#'
#' # For some models we have to specify additional arguments for the predict
#' # function
#' plot(FeatureEffect$new(mod, feature = "Petal.Width"))
#'
#' # FeatureEffect plots support up to two features:
#' eff <- FeatureEffect$new(mod, feature = c("Sepal.Length", "Petal.Length"))
#' eff$plot()
#'
#' # show where the actual data lies
#' eff$plot(show.data = TRUE)
#'
#' # For multiclass classification models, you can choose to only show one class:
#' mod <- Predictor$new(rf, data = iris, type = "prob", class = 1)
#' plot(FeatureEffect$new(mod, feature = "Sepal.Length"))
#' @name FeatureEffect
#' @seealso [plot.FeatureEffect]
#' @export
FeatureEffect <- R6Class("FeatureEffect",
  inherit = InterpretationMethod,

  public = list(

    #' @description Create a FeatureEffect object
    #' @template predictor
    #' @template feature
    #' @param method (`character(1)`)\cr
    #' - 'ale' for accumulated local effects,
    #' - 'pdp' for partial dependence plot,
    #' - 'ice' for individual conditional expectation curves,
    #' - 'pdp + ice' for partial dependence plot and ice curves within the same
    #' plot.
    #' @param center.at (`numeric(1)`)\cr
    #'   Value at which the plot should be centered. Ignored in the case of two
    #'   features.
    #' @template grid.size
    initialize = function(predictor, feature, method = "ale", center.at = NULL,
                          grid.size = 20) {
      feature_index <- private$sanitize.feature(
        feature,
        predictor$data$feature.names
      )
      assert_numeric(feature_index,
        lower = 1, upper = predictor$data$n.features,
        min.len = 1, max.len = 2
      )
      assert_numeric(grid.size, min.len = 1, max.len = length(feature))
      assert_number(center.at, null.ok = TRUE)
      assert_choice(method, c("ale", "pdp", "ice", "pdp+ice"))
      self$method <- method
      if (length(feature_index) == 2) {
        assert_false(feature_index[1] == feature_index[2])
        center.at <- NULL
        if (method %in% c("ice", "pdp+ice")) {
          stop("ICE is not implemented for two features.")
        }
      }
      private$anchor.value <- center.at
      super$initialize(predictor)
      private$set_feature_from_index(feature_index)
      if (length(feature_index) == 1 &&
        length(unique(self$predictor$data$get.x()[[feature_index]])) == 1) {
        stop("feature has only one unique value")
      }
      private$set.grid.size(grid.size)
      private$grid.size.original <- grid.size
      private$run(self$predictor$batch.size)
    },

    #' @field grid.size (`numeric(1)` | `numeric(2)`)\cr
    #'  The size of the grid.
    grid.size = NULL,

    #' @field feature.name (`character(1)` | `character(2)`)\cr
    #'   The names of the features for which the partial dependence was computed.
    feature.name = NULL,

    #' @field n.features (`numeric(1)`)\cr
    #'   The number of features (either 1 or 2).
    n.features = NULL,

    #' @field feature.type (`character(1)` | `character(2)`)\cr
    #'   The detected types of the features, either "categorical" or "numerical".
    feature.type = NULL,

    #' @field method (`character(1)`)\cr
    method = NULL,

    #' @description Get/set feature(s) (by index) for which to compute PDP.
    #' @param feature (`character(1)`)\cr
    #'   Feature name.
    set.feature = function(feature) {
      feature <- private$sanitize.feature(
        feature,
        self$predictor$data$feature.names
      )
      private$flush()
      private$set_feature_from_index(feature)
      private$set.grid.size(private$grid.size.original)
      private$run(self$predictor$batch.size)
    },

    #' @description Set the value at which the ice computations are centered.
    #' @param center.at (`numeric(1)`)\cr
    #'   Value at which the plot should be centered. Ignored in the case of two
    #'   features.
    center = function(center.at) {
      if (self$method == "ale") {
        warning("Centering only works for only for PDPs and ICE, but not for ALE Plots.")
        return(NULL)
      }
      private$anchor.value <- center.at
      private$flush()
      private$run(self$predictor$batch.size)
    },

    # Partial prediction function, which only looks at feature use in
    # FeatureEffect Returns value of ALE / PD curve at particular feature value

    #' @description Predict the marginal outcome given a feature.
    #' @param data [data.frame]\cr
    #'  Data.frame with the feature or a vector.
    #' @return Values of the effect curves at the given values.
    predict = function(data) {
      if (self$n.features == 2) stop("Only implemented for single feature")
      if (private$multiClass) stop("Only works for one-dimensional output")
      if (inherits(data, "data.frame")) {
        data <- data[, self$feature.name]
      }
      assert_vector(data)
      private$predict_inner(data)
    }
  ),
  private = list(
    run = function(n) {
      if (self$method == "ale") {
        private$run.ale()
      } else {
        private$run.pdp(self$predictor$batch.size)
      }

      # create the partial predict function
      if (self$n.features == 1 & !private$multiClass &
        self$method %in% c("ale", "pdp", "pdp+ice")) {
        if (self$feature.type == "numerical") {
          if (self$method == "ale") y <- self$results$.ale
          if (self$method %in% c("pdp", "pdp+ice")) {
            y <- self$results$.y.hat[self$results$.type == "pdp"]
          }
          x <- self$results[
            self$results$.type %in% c("ale", "pdp"),
            self$feature.name
          ]
          private$predict_inner <- approxfun(x = x, y = y)
        } else {
          private$predict_inner <- function(x) {
            df <- data.table(as.character(x), stringsAsFactors = FALSE)
            colnames(df) <- self$feature.name
            results <- self$results
            results[, self$feature.name] <- as.character(results[, self$feature.name])
            output_col <- ifelse(self$method == "ale", ".ale", ".y.hat")
            res <- merge(
              x = df, y = results, by = self$feature.name,
              all.x = TRUE, sort = FALSE
            )
            data.frame(res)[, output_col]
          }
        }
      }
    },

    anchor.value = NULL,
    grid.size.original = NULL,
    y_axis_label = NULL,
    # core functionality of self$predict
    predict_inner = NULL,
    run.ale = function() {
      private$dataSample <- private$getData()
      if (self$n.features == 1) {
        if (self$feature.type == "numerical") { # one numerical feature
          results <- calculate.ale.num(
            dat = private$dataSample, run.prediction = private$run.prediction,
            feature.name = self$feature.name, grid.size = self$grid.size
          )
        } else { # one categorical feature
          results <- calculate.ale.cat(
            dat = private$dataSample, run.prediction = private$run.prediction,
            feature.name = self$feature.name
          )
        }
      } else { # two features
        if (all(self$feature.type == "numerical")) { # two numerical features
          results <- calculate.ale.num.num(
            dat = private$dataSample, run.prediction = private$run.prediction,
            feature.name = self$feature.name, grid.size = self$grid.size
          )
        } else if (all(self$feature.type == "categorical")) { # two categorical features
          stop("ALE for two categorical features is not yet implemented.")
        } else { # mixed numerical and categorical
          results <- calculate.ale.num.cat(
            dat = private$dataSample, run.prediction = private$run.prediction,
            feature.name = self$feature.name, grid.size = self$grid.size
          )
        }
      }
      # only keep .class when multiple outputs
      if (!private$multiClass) results$.class <- NULL
      self$results <- results
    },
    run.pdp = function(n) {
      private$dataSample <- private$getData()
      grid.dt <- get.grid(private$getData()[, self$feature.name, with = FALSE],
        self$grid.size,
        anchor.value = private$anchor.value
      )
      mg <- MarginalGenerator$new(grid.dt, private$dataSample,
        self$feature.name,
        id.dist = TRUE, cartesian = TRUE
      )
      results.ice <- data.table()
      while (!mg$finished) {
        results.ice.inter <- mg$next.batch(n)
        predictions <- private$run.prediction(results.ice.inter)
        results.ice.inter <- results.ice.inter[, c(self$feature.name, ".id.dist"),
          with = FALSE
        ]
        if (private$multiClass) {
          y.hat.names <- colnames(predictions)
          results.ice.inter <- cbind(results.ice.inter, predictions)
          results.ice.inter <- data.table::melt(results.ice.inter,
            variable.name = ".class",
            value.name = ".y.hat", measure.vars = y.hat.names
          )
        } else {
          results.ice.inter$.y.hat <- predictions
          results.ice.inter$.class <- 1
        }
        results.ice <- rbind(results.ice, results.ice.inter)
      }

      if (!is.null(private$anchor.value)) {
        anchor.index <- which(results.ice[, self$feature.name, with = FALSE] == private$anchor.value)
        X.aggregated.anchor <- results.ice[anchor.index,
          c(".y.hat", ".id.dist", ".class"),
          with = FALSE
        ]
        names(X.aggregated.anchor) <- c("anchor.yhat", ".id.dist", ".class")
        # In case that the anchor value was also part of grid
        X.aggregated.anchor <- unique(X.aggregated.anchor)
        results.ice <- merge(results.ice, X.aggregated.anchor,
          by = c(".id.dist", ".class")
        )
        results.ice$.y.hat <- results.ice$.y.hat - results.ice$anchor.yhat
        results.ice$anchor.yhat <- NULL
      }
      results <- data.table()
      if (self$method %in% c("pdp", "pdp+ice")) {
        if (private$multiClass) {
          results.aggregated <- results.ice[, list(.y.hat = mean(.y.hat)),
            by = c(self$feature.name, ".class")
          ]
        } else {
          results.aggregated <- results.ice[, list(.y.hat = mean(.y.hat)),
            by = c(self$feature.name)
          ]
        }
        results.aggregated$.type <- "pdp"
        results <- rbind(results, results.aggregated)
      }
      if (!private$multiClass) {
        results.ice$.class <- NULL
      }
      if (self$method %in% c("ice", "pdp+ice")) {
        results.ice$.type <- "ice"
        results <- rbind(results, results.ice, fill = TRUE)
        results$.id <- results$.id.dist
        results$.id.dist <- NULL
        # sory by id
        setkeyv(results, ".id")
      }
      self$results <- data.frame(results)
    },
    set_feature_from_index = function(feature.index) {
      self$n.features <- length(feature.index)
      self$feature.type <- private$sampler$feature.types[feature.index]
      self$feature.name <- private$sampler$feature.names[feature.index]
    },
    printParameters = function() {
      cat("features:", paste(sprintf(
        "%s[%s]",
        self$feature.name, self$feature.type
      ), collapse = ", "))
      cat("\ngrid size:", paste(self$grid.size, collapse = "x"))
    },
    # make sure the default arguments match with plot.FeatureEffect
    generatePlot = function(rug = TRUE, show.data = FALSE, ylim = NULL) {
      requireNamespace("ggplot2", quietly = TRUE)
      if (is.null(ylim)) ylim <- c(NA, NA)
      if (is.null(private$anchor.value)) {
        if (self$method == "ale") {
          private$y_axis_label <- "ALE"
          if (!is.null(self$predictor$data$y.names) & self$n.features == 1) {
            axis_label_names <- paste(self$predictor$data$y.names, sep = ", ")
            private$y_axis_label <- sprintf("ALE of %s", axis_label_names)
          }
        } else {
          private$y_axis_label <- expression(hat(y))
          if (!is.null(self$predictor$data$y.names) & self$n.features == 1) {
            axis_label_names <- paste(self$predictor$data$y.names, sep = ", ")
            private$y_axis_label <- sprintf("Predicted %s", axis_label_names)
          }
        }
      } else {
        private$y_axis_label <- sprintf(
          "Prediction centered at x = %s",
          as.character(private$anchor.value)
        )
      }

      if (self$n.features == 1) {
        y.name <- ifelse(self$method == "ale", ".ale", ".y.hat")
        p <- ggplot2::ggplot(self$results,
          mapping = ggplot2::aes_string(x = self$feature.name, y = y.name)
        ) +
          ggplot2::scale_y_continuous(private$y_axis_label, limits = ylim)
        if (self$feature.type == "categorical") {
          if (self$method %in% c("ice", "pdp+ice")) {
            p <- p + ggplot2::geom_boxplot(data = self$results[self$results$.type == "ice", ], ggplot2::aes_string(group = self$feature.name))
          } else {
            p <- p + ggplot2::geom_col()
          }
        } else {
          if (self$method %in% c("ice", "pdp+ice")) {
            p <- p + ggplot2::geom_line(alpha = 0.2, mapping = ggplot2::aes(group = .id))
          }
          if (self$method == "pdp+ice") {
            aggr <- self$results[self$results$.type != "ice", ]
            p <- p + ggplot2::geom_line(data = aggr, size = 2, color = "gold")
          }
          if (self$method %in% c("ale", "pdp")) {
            p <- p + ggplot2::geom_line()
          }
        }
      } else if (self$n.features == 2) {
        if (self$method == "ale") {
          # 2D ALEPlot with categorical x numerical
          if (any(self$feature.type %in% "categorical")) {
            res <- self$results
            categorical.feature <- self$feature.name[self$feature.type == "categorical"]
            numerical.feature <- setdiff(self$feature.name, categorical.feature)
            res[, categorical.feature] <- as.numeric(res[, categorical.feature])
            cat.breaks <- unique(res[[categorical.feature]])
            cat.labels <- levels(self$results[[categorical.feature]])[cat.breaks]
            p <- ggplot2::ggplot(res, ggplot2::aes_string(x = categorical.feature, y = numerical.feature)) +
              ggplot2::geom_rect(aes(ymin = .bottom, ymax = .top, fill = .ale, xmin = .left, xmax = .right)) +
              ggplot2::scale_x_continuous(categorical.feature, breaks = cat.breaks, labels = cat.labels) +
              ggplot2::scale_y_continuous(numerical.feature) +
              ggplot2::scale_fill_continuous(private$y_axis_label)

            # A bit stupid, but adding a rug is special here, because i handle the
            # categorical feature as a numeric feauture in the plot
            if (rug) {
              dat <- private$sampler$get.x()
              levels(dat[[categorical.feature]]) <- levels(self$results[, categorical.feature])
              dat[, categorical.feature] <- as.numeric(dat[, categorical.feature,
                with = FALSE
              ][[1]])
              # Need some dummy data for ggplot to accept the data.frame
              rug.dat <- cbind(dat, data.frame(.y.hat = 1, .id = 1, .ale = 1))
              p <- p + ggplot2::geom_rug(
                data = rug.dat, alpha = 0.2, sides = "bl",
                position = ggplot2::position_jitter(width = 0.07, height = 0.07)
              )
              rug <- FALSE
            }
            if (show.data) {
              dat <- private$sampler$get.x()
              levels(dat[[categorical.feature]]) <- levels(self$results[, categorical.feature])
              dat[, categorical.feature] <- as.numeric(dat[, categorical.feature, with = FALSE][[1]])
              p <- p + ggplot2::geom_point(data = dat, alpha = 0.3)
              show.data <- FALSE
            }
          } else {
            # Adding x and y to aesthetics for the rug plot later
            p <- ggplot2::ggplot(self$results, mapping = ggplot2::aes_string(x = self$feature.name[1], y = self$feature.name[2])) +
              ggplot2::geom_rect(aes(xmin = .left, xmax = .right, ymin = .bottom, ymax = .top, fill = .ale)) +
              ggplot2::scale_x_continuous(self$feature.name[1]) +
              ggplot2::scale_y_continuous(self$feature.name[2]) +
              ggplot2::scale_fill_continuous(private$y_axis_label)
          }
        } else if (all(self$feature.type %in% "numerical") | all(self$feature.type %in% "categorical")) {
          p <- ggplot2::ggplot(self$results, mapping = ggplot2::aes_string(
            x = self$feature.name[1],
            y = self$feature.name[2]
          )) +
            ggplot2::geom_tile(aes(fill = .y.hat)) +
            ggplot2::scale_fill_continuous(private$y_axis_label)
        } else {
          categorical.feature <- self$feature.name[self$feature.type == "categorical"]
          numerical.feature <- setdiff(self$feature.name, categorical.feature)
          p <- ggplot2::ggplot(self$results, mapping = ggplot2::aes_string(x = numerical.feature, y = ".y.hat")) +
            ggplot2::geom_line(ggplot2::aes_string(group = categorical.feature, color = categorical.feature)) +
            ggplot2::scale_y_continuous(private$y_axis_label)
          show.data <- FALSE
        }

        if (show.data) {
          dat <- private$sampler$get.x()
          dat[, self$feature.name] <- lapply(dat[, self$feature.name, with = FALSE], as.numeric)
          p <- p + ggplot2::geom_point(data = dat, alpha = 0.3)
        }
      }
      if (rug) {
        # Need some dummy data for ggplot to accept the data.frame
        rug.dat <- private$sampler$get.x()
        rug.dat$.id <- ifelse(is.null(self$results$.id), NA,
          self$results$.id[1]
        )
        rug.dat$.ale <- ifelse(is.null(self$results$.ale), NA,
          self$results$.ale[1]
        )
        rug.dat$.y.hat <- ifelse(is.null(self$results$.y.hat), NA,
          self$results$.y.hat[1]
        )
        sides <- ifelse(self$n.features == 2 &&
          self$feature.type[1] == self$feature.type[2], "bl", "b")

        if (sides == "b") {
          jitter_height <- 0
          if (self$feature.type[1] == "numerical") {
            jitter_width <- 0.01 * diff(range(rug.dat[, self$feature.name[1],
              with = FALSE
            ][[1]]))
          } else {
            jitter_width <- 0.07
          }
        } else {
          if (all(self$feature.type == "numerical")) {
            jitter_width <- 0.01 * diff(range(rug.dat[, self$feature.name[1],
              with = FALSE
            ][[1]]))
            jitter_height <- 0.01 * diff(range(rug.dat[, self$feature.name[2],
              with = FALSE
            ][[1]]))

          } else {
            jitter_width <- 0.07
            jitter_height <- 0.07
          }
        }

        p <- p + ggplot2::geom_rug(
          data = rug.dat, alpha = 0.2, sides = sides,
          position = ggplot2::position_jitter(width = jitter_width, height = jitter_height)
        )
      }
      if (private$multiClass) {
        p <- p + ggplot2::facet_wrap(".class")
      }
      p
    },
    # This function ensures that the grid is always of length 2 when 2 features are provided
    set.grid.size = function(size) {
      self$grid.size <- numeric(length = self$n.features)
      names(self$grid.size) <- self$feature.name
      private$set.grid.size.single(size[1], 1)
      if (self$n.features > 1) {
        if (length(size) == 1) {
          # If user only provided 1D grid size
          private$set.grid.size.single(size[1], 2)
        } else {
          # If user provided 2D grid.size
          private$set.grid.size.single(size[2], 2)
        }
      }
    },
    set.grid.size.single = function(size, feature.number) {
      self$grid.size[feature.number] <- ifelse(self$feature.type[feature.number] == "numerical",
        size, length(unique(private$sampler$get.x()[[self$feature.name[feature.number]]]))
      )
    },
    sanitize.feature = function(feature, feature.names) {
      if (is.character(feature)) {
        feature.char <- feature
        stopifnot(all(feature %in% feature.names))
        feature <- which(feature.char[1] == feature.names)
        if (length(feature.char) == 2) {
          feature <- c(feature, which(feature.char[2] == feature.names))
        }
      }
      feature
    }
  ),
  active = list(

    #' @field center.at [numeric]\cr
    #'  Value at which the plot was centered. Ignored in the case of two
    #'  features.
    center.at = function() {
      return(private$anchor.value)
    }
  )
)

# Plot.FeatureEffect -----------------------------------------------------------

#' Plot FeatureEffect
#'
#' `plot.FeatureEffect()` plots the results of a [FeatureEffect] object.
#'
#' @param x A [FeatureEffect] object.
#' @param rug [logical]\cr
#'   Should a rug be plotted to indicate the feature distribution? The rug will
#'   be jittered a bit, so the location may not be exact, but it avoids
#'   overplotting.
#' @param show.data (`logical(1)`)\cr
#'   Should the data points be shown? Only affects 2D plots, and ignored for 1D
#'   plots, because rug has the same information.
#' @param ylim (`numeric(2)`)\cr Vector with two coordinates for the y-axis.
#'   Only works when one feature is used in [FeatureEffect], ignored when two
#'   are used.
#' @return ggplot2 plot object
#' @seealso [FeatureEffect]
#' @examples
#' # We train a random forest on the Boston dataset:
#' if (require("randomForest")) {
#'   data("Boston", package = "MASS")
#'   rf <- randomForest(medv ~ ., data = Boston, ntree = 50)
#'   mod <- Predictor$new(rf, data = Boston)
#'
#'   # Compute the ALE for the first feature
#'   eff <- FeatureEffect$new(mod, feature = "crim")
#'
#'   # Plot the results directly
#'   plot(eff)
#' }
plot.FeatureEffect <- function(x, rug = TRUE, show.data = FALSE, ylim = NULL) {
  assert_numeric(
    x = ylim, len = 2, all.missing = TRUE, any.missing = TRUE,
    null.ok = TRUE
  )
  x$plot(rug = rug, show.data = show.data, ylim = ylim)
}


# Partial ----------------------------------------------------------------------

#' Effect of one or two feature(s) on the model predictions (deprecated)
#'
#' Deprecated, please use [FeatureEffect].
#'
#' @name Partial
#'
#' @seealso [FeatureEffect]
#' @export
Partial <- R6Class("Partial",
  inherit = FeatureEffect,

  public = list(

    #' @description Effect of one or two feature(s) on the model predictions
    #' @param predictor [Predictor]\cr
    #'   The object (created with `Predictor$new()`) holding the machine
    #'   learning model and the data.
    #' @param feature (`character(1)` | `character(2)` | `numeric(1)` |
    #'   `numeric(2)`)\cr
    #'   The feature name or index for which to compute the effects.
    #' @param aggregation (`character(1)`)\cr
    #'   The aggregation approach to use. Possible values are `"pdp"`,
    #'   `"ale"` or `"none"`.
    #' @param ice [logical]\cr
    #'   Whether to compute ice plots.
    #' @param center.at (`numeric(1)`)\cr
    #'   Value at which the plot should be centered. Ignored in the case of two
    #'   features.
    #' @param grid.size (`numeric(1)` | `numeric(2)`)\cr
    #'   The size of the grid for evaluating the predictions.
    initialize = function(predictor, feature, aggregation = "pdp", ice = TRUE,
                          center.at = NULL, grid.size = 20) {
      assert_choice(aggregation, c("ale", "pdp", "none"))
      assert_logical(ice)
      .Deprecated("FeatureEffect", old = "Partial")
      if (length(feature) == 2) ice <- FALSE
      if (aggregation == "none") method <- "ice"
      if ((aggregation == "pdp") & ice) method <- "pdp+ice"
      if ((aggregation == "pdp") & !ice) method <- "pdp"
      if (aggregation == "ale") method <- "ale"
      super$initialize(
        predictor = predictor, feature = feature, method = method,
        center.at = center.at, grid.size = grid.size
      )
    }
  )
)
