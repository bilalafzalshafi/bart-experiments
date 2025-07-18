# Comparison script for semiparametric regression models

library(dbarts)
source("helper_funs.R")
source("source_sba.R") 
source("sbart.R")
source("bbart_bc.R")
source("slice.R")
source("simulation_helpers.R")

set.seed(123)

scenario_name <- "sigmoid"  # Change this to test different scenarios
cat("Testing scenario:", scenario_name, "\n")

sim_data <- simulate_sbart_data(n_train = 200, n_test = 1000, p = 10, 
                               scenario = scenario_name, seed = 123)
y <- sim_data$y_train
y_test <- sim_data$y_test
X <- sim_data$X_train
X_test <- sim_data$X_test
g_true <- sim_data$g_true

results = list()
timing = list()

cat("Fitting models...\n")

# 1. Regular BART (no transformation)
cat("Fitting regular BART...\n")
timing$bart = system.time({
  tryCatch({
    fit_bart = bart(x.train = X, y.train = y, x.test = X_test, 
                    ntree = 200, ndpost = 1000, nskip = 1000, verbose = FALSE)
    results$bart = list(
      fitted.values = fit_bart$yhat.test.mean,
      post_ypred = fit_bart$yhat.test,
      model = 'bart'
    )
  }, error = function(e) {
    cat("BART failed:", e$message, "\n")
    results$bart <<- NULL
  })
})

# 2. Semiparametric BART (sbart)
cat("Fitting sbart...\n")
timing$sbart = system.time({
  tryCatch({
    fit_sbart = sbart(y = y, X = X, X_test = X_test, 
                      ntree = 200, nsave = 1000, nburn = 1000, verbose = FALSE)
    results$sbart = fit_sbart
  }, error = function(e) {
    cat("SBART failed:", e$message, "\n")
    results$sbart <<- NULL
  })
})

# 3. Semiparametric Bayesian Linear Model (sblm)
cat("Fitting sblm...\n")
timing$sblm = system.time({
  tryCatch({
    fit_sblm = sblm(y = y, X = X, X_test = X_test)
    results$sblm = fit_sblm
  }, error = function(e) {
    cat("SBLM failed:", e$message, "\n")
    results$sblm <<- NULL
  })
})

# 4. Bayesian BART with Box-Cox (bbart_bc)
cat("Fitting bbart_bc...\n")
timing$bbart_bc = system.time({
  tryCatch({
    fit_bbart_bc = bbart_bc(y = y, X = X, X_test = X_test,
                            ntree = 200, nsave = 1000, nburn = 1000, verbose = FALSE)
    results$bbart_bc = fit_bbart_bc
  }, error = function(e) {
    cat("BBART_BC failed:", e$message, "\n")
    results$bbart_bc <<- NULL
  })
})

cat("\nEvaluating performance...\n")

# Calculate RMSE for each model
rmse = function(pred, true) sqrt(mean((pred - true)^2))

performance = data.frame(
  Model = character(),
  RMSE = numeric(),
  Time_sec = numeric(),
  Coverage_90 = numeric(),
  Mean_Width = numeric(),
  stringsAsFactors = FALSE
)

# Calculate coverage rates (90% prediction intervals)
calc_coverage = function(post_pred, y_true, alpha = 0.1) {
  if (is.null(post_pred)) return(NA)
  lower = apply(post_pred, 2, quantile, alpha/2, na.rm = TRUE)
  upper = apply(post_pred, 2, quantile, 1 - alpha/2, na.rm = TRUE)
  mean(y_true >= lower & y_true <= upper, na.rm = TRUE)
}

# Calculate mean interval width
calc_mean_width = function(post_pred, alpha = 0.1) {
  if (is.null(post_pred)) return(NA)
  lower = apply(post_pred, 2, quantile, alpha/2, na.rm = TRUE)
  upper = apply(post_pred, 2, quantile, 1 - alpha/2, na.rm = TRUE)
  mean(upper - lower, na.rm = TRUE)
}

for (model_name in names(results)) {
  if (!is.null(results[[model_name]])) {
    
    model_rmse = rmse(results[[model_name]]$fitted.values, y_test)
    model_time = timing[[model_name]][3]
    model_coverage = calc_coverage(results[[model_name]]$post_ypred, y_test)
    model_width = calc_mean_width(results[[model_name]]$post_ypred)
    
    performance = rbind(performance, data.frame(
      Model = model_name,
      RMSE = model_rmse,
      Time_sec = model_time,
      Coverage_90 = model_coverage,
      Mean_Width = model_width,
      stringsAsFactors = FALSE
    ))
  }
}

print(performance)

par(mfrow = c(2, 2))

model_names <- c("bart", "sbart", "sblm", "bbart_bc")
plot_titles <- c("BART", "SBART", "SBLM", "BBART_BC")

for (i in 1:4) {
  if (model_names[i] %in% names(results) && !is.null(results[[model_names[i]]])) {
    plot(y_test, results[[model_names[i]]]$fitted.values, 
         main = plot_titles[i], 
         xlab = "True", ylab = "Predicted", pch = 16, cex = 0.5,
         xlim = range(y_test), ylim = range(y_test))
    abline(0, 1, col = "red")
    
    model_rmse <- performance$RMSE[performance$Model == model_names[i]]
    if (length(model_rmse) > 0) {
      text(min(y_test) + 0.1 * diff(range(y_test)), 
           max(y_test) - 0.1 * diff(range(y_test)),
           paste("RMSE:", round(model_rmse, 3)), 
           cex = 0.8, col = "blue")
    }
  } else {
    plot(1, 1, type = "n", main = paste(plot_titles[i], "- Failed"), 
         xlab = "", ylab = "")
    text(1, 1, "Model failed", cex = 1.5, col = "red")
  }
}

par(mfrow = c(1, 1))

dev.new()
par(mfrow = c(1, 3))

if (!is.null(results$sbart$post_g)) {
  y_unique = sort(unique(y))
  g_mean = colMeans(results$sbart$post_g)
  
  if (length(y_unique) == length(g_mean)) {
    plot(y_unique, g_mean, main = "SBART Transformation", 
         xlab = "y", ylab = "g(y)", type = "l", lwd = 2)
    
    # Add some posterior draws for uncertainty
    n_draws = min(50, nrow(results$sbart$post_g))
    for (i in sample(1:nrow(results$sbart$post_g), n_draws)) {
      lines(y_unique, results$sbart$post_g[i,], col = "gray", lwd = 0.5)
    }
    lines(y_unique, g_mean, lwd = 2, col = "black")
  }
}

if(!is.null(results$sblm$post_g)) {
  y_unique = sort(unique(y))
  g_mean = colMeans(results$sblm$post_g)
  
  if(length(y_unique) == length(g_mean)) {
    plot(y_unique, g_mean, main = "SBLM Transformation", 
         xlab = "y", ylab = "g(y)", type = "l", lwd = 2)
    
    # Add some posterior draws for uncertainty
    n_draws = min(50, nrow(results$sblm$post_g))
    for (i in sample(1:nrow(results$sblm$post_g), n_draws)) {
      lines(y_unique, results$sblm$post_g[i,], col = "gray", lwd = 0.5)
    }
    lines(y_unique, g_mean, lwd = 2, col = "black")
  }
}

if (!is.null(results$bbart_bc$post_lambda)) {
  lambda_mean = mean(results$bbart_bc$post_lambda)
  lambda_sd = sd(results$bbart_bc$post_lambda)
  
  hist(results$bbart_bc$post_lambda, main = paste("BBART_BC λ posterior"), 
       xlab = "λ", col = "lightblue", border = "black")
  abline(v = lambda_mean, col = "red", lwd = 2)
  text(lambda_mean, max(hist(results$bbart_bc$post_lambda, plot = FALSE)$counts) * 0.8,
       paste("Mean:", round(lambda_mean, 3)), pos = 4, col = "red")
}

par(mfrow = c(1, 1))

cat("\n=== SUMMARY FOR", toupper(scenario_name), "SCENARIO ===\n")
cat("Description:", sim_data$description, "\n\n")

if (nrow(performance) > 0) {
  best_rmse_idx = which.min(performance$RMSE)
  best_coverage_idx = which.min(abs(performance$Coverage_90 - 0.9))
  fastest_idx = which.min(performance$Time_sec)
  
  cat("Best RMSE:", performance$Model[best_rmse_idx], 
      "(", round(performance$RMSE[best_rmse_idx], 4), ")\n")
  cat("Best Coverage:", performance$Model[best_coverage_idx], 
      "(", round(performance$Coverage_90[best_coverage_idx], 3), ")\n")
  cat("Fastest:", performance$Model[fastest_idx], 
      "(", round(performance$Time_sec[fastest_idx], 1), "sec)\n")
} else {
  cat("No models completed successfully.\n")
}

# Special diagnostic for beta scenario (since data is bounded [0,1])
if (scenario_name == "beta") {
  cat("\n=== BETA SCENARIO DIAGNOSTICS ===\n")
  cat("Data should be bounded [0,1] with many values near 0\n")
  cat("Proportion < 0.1:", round(mean(y < 0.1), 3), "\n")
  cat("Proportion > 0.9:", round(mean(y > 0.9), 3), "\n")
  cat("Median:", round(median(y), 3), "\n")
  
  # Check if models respect the [0,1] constraint
  for (model_name in names(results)) {
    if (!is.null(results[[model_name]])) {
      pred_range = range(results[[model_name]]$fitted.values)
      in_bounds = all(results[[model_name]]$fitted.values >= 0 & 
                      results[[model_name]]$fitted.values <= 1)
      cat(toupper(model_name), "predictions: [", round(pred_range[1], 3), ",", 
          round(pred_range[2], 3), "] - In bounds:", in_bounds, "\n")
    }
  }
}