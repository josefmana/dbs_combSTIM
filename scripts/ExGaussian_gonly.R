# This script is used to diagnose ExGaussian model of SSRT data implemented in Stan.

rm( list = ls() )
options( mc.cores = parallel::detectCores() )

# recommended running this is a fresh R session or restarting current session
# install.packages( "cmdstanr", repos = c( "https://mc-stan.org/r-packages/", getOption("repos") ) )

library(here)
library(tidyverse)
library(brms)
library(bayesplot)
library(cmdstanr)

# maximum time allow was 1.5 s
rtmax <- 1.5

# read data
d0 <- read.csv( here("_data","ssrt_lab.csv"), sep = "," )

# pivot it wider
d1 <-
  d0 %>%
  mutate( cens = ifelse( correct == "missed", "right", "none" ), max = rtmax ) %>% # add censoring info and maximum possible RTs
  filter( block != 0 ) %>%
  select( id, block, cond, signal, rt1, trueSOA, cens, max ) %>%
  rename( "rt" = "rt1", "ssd" = "trueSOA" ) %>%
  mutate( across( c("rt","ssd"), ~ .x/1e3 ) ) # re-scale from ms to s

# separate files for "go" and "stop" trials
Dgo <- d1 %>% filter( signal == "nosignal" )
Dsr <- d1 %>% filter( signal == "signal" & !is.na(rt) )
Dna <- d1 %>% filter( signal == "signal" & is.na(rt) ) %>% mutate( rt = rtmax, cens = "right" )


# PRIOR PREDICTION ----

# prepare a function computing and summarising mean and sd of ExGaussian based on priors
priorpred <- function( mu = c(.7,.5), sigma = c(-6,2), tau = c(-4.3,1.3), sd = c(0,.1), rep = 1e5 ) {
  
  m <- rnorm( rep, mu[1], mu[2] ) + rnorm( rep, 0, abs( rnorm( rep, sd[1], sd[2] ) ) ) + exp( rnorm( rep, tau[1], tau[2] ) )
  sd <- sqrt( exp( rnorm( rep, sigma[1], sigma[2] ) )^2 + exp( rnorm( rep, tau[1], tau[2] ) )^2 )
  
  return( summary( cbind(M = m, SD = sd) ) )
  
}

# MODEL FITTING ----

# drop rows with missing data in Go trials
GOcon <- subset( Dgo, complete.cases(rt) & cond == "ctrl" ) %>% mutate( id = as.integer( as.factor(id) ) )
GOexp <- subset( Dgo, complete.cases(rt) & cond == "exp" ) %>% mutate( id = as.integer( as.factor(id) ) ) 

# prepare the model
mod <- cmdstan_model( here("mods","ExGaussian_gonly.stan") )

# prepare input
dlist <- list(
  
  # data
  Y_0 = GOcon$rt, N_0 = nrow(GOcon), J_0 = GOcon$id, Z_0_1 = rep( 1, nrow(GOcon) ),
  Y_1 = GOexp$rt, N_1 = nrow(GOexp), J_1 = GOexp$id, Z_1_1 = rep( 1, nrow(GOexp) ),
  K = length( unique(GOcon$id) ), M = 1,
  
  # priors
  mu_0p = c(-.4,.2), sigma_0p = c(-2,.2), beta_0p = c(-2,.2),
  mu_1p = c(-.4,.2), sigma_1p = c(-2,.2), beta_1p = c(-2,.2),
  tau_mu_p = c(0,.5), tau_sigma_p = c(0,.3), tau_beta_p = c(0,.3)
  
)

# fit the model
fit <- mod$sample( data = dlist, chains = 4 )

# check trace plots
mcmc_trace( fit$draws() )


# POSTERIOR PREDICTION ----

# extract draws
post <- fit$draws(format = "matrix")

# predict separately results for control and experimental condition
d_seq <- with(

  dlist,
  list( con = data.frame( rt = Y_0, id = J_0, cond = "con" ), exp = data.frame( rt = Y_1, id = J_1, cond = "exp" ) )
  
)

# predict control condition data
con_pred <-
  
  sapply(
    
    1:nrow(d_seq$con),
    function(i) {
      
      print( paste0("row #",i," out of ",nrow(d_seq$con) ) )
      
      rexgaussian(
        nrow(post),
        mu = exp( post[ ,"InterceptMu_0"] + post[ ,paste0("r_mu[",d_seq$con$id[i],"]") ] ),
        sigma = exp( post[ ,"InterceptSigma_0"] + post[ ,paste0("r_sigma[",d_seq$con$id[i],"]") ] ),
        beta = exp( post[ ,"InterceptBeta_0"] + post[ ,paste0("r_beta[",d_seq$con$id[i],"]") ] )
      )

    }
  )

# predict experimental condition data
exp_pred <-
  
  sapply(
    
    1:nrow(d_seq$exp),
    function(i) {
      
      print( paste0("row #",i," out of ",nrow(d_seq$exp) ) )
      
      rexgaussian(
        nrow(post),
        mu = exp( post[ ,"InterceptMu_1"] + post[ ,paste0("r_1_mu[",d_seq$exp$id[i],"]") ] ),
        sigma = exp( post[ ,"InterceptSigma_1"] + post[ ,paste0("r_1_sigma[",d_seq$exp$id[i],"]") ] ),
        beta = exp( post[ ,"InterceptBeta_1"] + post[ ,paste0("r_1_beta[",d_seq$exp$id[i],"]") ] )
      )
      
    }
  )

# check posterior stats
d_pred <-
  do.call( rbind.data.frame, d_seq ) %>%
  mutate( conid = paste0(cond,"_",id) ) %>%
  mutate( conid = factor( conid, levels = c( paste0("con_",1:4), paste0("exp_",1:4), paste0("con_",5:8), paste0("exp_",5:8) ), ordered = T ) )

ppc_stat_grouped( y = d_pred$rt, yrep = cbind(con_pred,exp_pred), group = d_pred$conid, stat = "mean" )
ppc_dens_overlay_grouped( y = d_pred$rt, yrep = cbind(con_pred,exp_pred)[ sample(1:4000,100) , ], group = d_pred$conid )
