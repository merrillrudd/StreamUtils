
#' Build objects related to spatial information
#'
#' \code{make_spatial_info} builds a tagged list with all the spatial information needed for \code{Data_Fn}
#'
#' @param n_x, the number of nodes in the stream network
#' @param Lon_i, Longitude for each sample
#' @param Lat_i, Latitude for each sample
#' @param Lon_x, Longitude for each child node
#' @param Lat_x, Latitude for each child node
#' @param Network_sz data frame of network information including column names 'parent_s', 'child_s', 'dist_s'
#' @param Method, a character of either "Grid" or "Mesh" where "Grid" is a 2D AR1 process, and "Mesh" is the SPDE method with geometric anisotropy
#' @param Extrapolation_List, the output from \code{Prepare_Extrapolation_Data_Fn}
#' @param grid_size_km, the distance between grid cells for the 2D AR1 grid (determines spatial resolution when Method="Grid") when not using \code{Method="Spherical_mesh"}
#' @param grid_size_LL, the distance between grid cells for the 2D AR1 grid (determines spatial resolution when Method="Grid") when using \code{Method="Spherical_mesh"}
#' @param ..., additional arguments passed to \code{Calc_Kmeans}
#' @inheritParams Calc_Kmeans

#' @return Tagged list containing objects for running a VAST model
#' \describe{
#'   \item{MeshList}{A tagged list with inputs related to the SPDE mesh}
#'   \item{GridList}{A tagged list with inputs related to the 2D AR1 grid}
#'   \item{a_xl}{A data frame with areas for each knot and each strattum}
#'   \item{loc_UTM}{A data frame with the converted UTM coordinates for each sample}
#'   \item{Kmeans}{Output from \code{Calc_Kmeans} with knots for a triangulated mesh}
#'   \item{knot_i}{The knot associated with each sample}
#'   \item{Method}{The Method input (for archival purposes)}
#'   \item{loc_x}{The UTM location for each knot}
#' }

#' @export
make_spatial_info = function( n_x, Network_sz, Lon_i, Lat_i, Lon_x, Lat_x, Extrapolation_List, Method="Mesh", grid_size_km=50, grid_size_LL=1,
  randomseed=1, nstart=100, iter.max=1000, ... ){

  if(Method != "Stream_network"){
    stop("StreamUtils::make_spatial_info is for the stream network spatial model only. Please use FishStatsUtils::make_spatial_info for other spatial models.")
  }
  if( is.numeric(Extrapolation_List$zone) ){
    # Locations for samples
    loc_i = Convert_LL_to_UTM_Fn( Lon=Lon_i, Lat=Lat_i, zone=Extrapolation_List$zone, flip_around_dateline=Extrapolation_List$flip_around_dateline )                                                         #$
    loc_i = cbind( 'E_km'=loc_i[,'X'], 'N_km'=loc_i[,'Y'])
    # Locations for locations for knots
    loc_x = Convert_LL_to_UTM_Fn( Lon=Lon_x, Lat=Lat_x, zone=Extrapolation_List$zone, flip_around_dateline=Extrapolation_List$flip_around_dateline )                                                         #$
    loc_x = cbind( 'E_km'=loc_x[,'X'], 'N_km'=loc_x[,'Y'])
  }else{
    loc_i = Convert_LL_to_EastNorth_Fn( Lon=Lon_i, Lat=Lat_i, crs=Extrapolation_List$zone )
    loc_x = Convert_LL_to_EastNorth_Fn( Lon=Lon_x, Lat=Lat_x, crs=Extrapolation_List$zone )
  }
  # Bounds for 2D AR1 grid
  ### NOT USED FOR STREAM NETWORK -- DOESNT MATTER
  Grid_bounds = grid_size_km * apply(Extrapolation_List$Data_Extrap[,c('E_km','N_km')]/grid_size_km, MARGIN=2, FUN=function(vec){trunc(range(vec))+c(0,1)})

  # Calculate k-means centroids
  Kmeans = Calc_Kmeans(n_x=n_x, loc_orig=loc_x[,c("E_km", "N_km")], randomseed=randomseed)#, ... )
  # NN_i = RANN::nn2( data=Kmeans[["centers"]], query=loc_i, k=1)$nn.idx[,1]
  ## use actual upstream child node for stream network
  NN_i = Extrapolation_List$Data_Extrap[,"child_i"]

  # Calculate grid for 2D AR1 process
  ### NOT USED FOR STREAM NETWORK --- DOESNT MATTER
  loc_grid = expand.grid( 'E_km'=seq(Grid_bounds[1,1],Grid_bounds[2,1],by=grid_size_km), 'N_km'=seq(Grid_bounds[1,2],Grid_bounds[2,2],by=grid_size_km) )
  Which = sort(unique(RANN::nn2(data=loc_grid, query=Extrapolation_List$Data_Extrap[which(Extrapolation_List$Area_km2_x>0),c('E_km','N_km')], k=1)$nn.idx[,1]))
  loc_grid = loc_grid[Which,]
  grid_num = RANN::nn2( data=loc_grid, query=loc_i, k=1)$nn.idx[,1]

  ## use actual upstream child nodes for stream network
  knot_i = NN_i
  # loc_x = Kmeans[["centers"]]

  PolygonList = Calc_Polygon_Areas_and_Polygons_Fn( loc_x=loc_x, Data_Extrap=Extrapolation_List[["Data_Extrap"]], a_el=Extrapolation_List[["a_el"]])
  
  ## use actual area for each node in stream network
  dist_inp <- Network_sz$dist_s
  dist_inp[which(is.infinite(dist_inp))] <- 0
  a_xl = matrix(dist_inp,nrow=n_x) #PolygonList[["a_xl"]]

  # Make mesh and info for anisotropy  SpatialDeltaGLMM::
  ## loc_x directly calculated from known locations on stream network
  MeshList = Calc_Anisotropic_Mesh( Method=Method, loc_x=loc_x )

  # Make matrices for 2D AR1 process
  Dist_grid = dist(loc_grid, diag=TRUE, upper=TRUE)
  M0 = as( ifelse(as.matrix(Dist_grid)==0, 1, 0), "dgTMatrix" )
  M1 = as( ifelse(as.matrix(Dist_grid)==grid_size_km, 1, 0), "dgTMatrix" )
  M2 = as( ifelse(as.matrix(Dist_grid)==sqrt(2)*grid_size_km, 1, 0), "dgTMatrix" )
  if( Method=="Spherical_mesh" ) GridList = list("M0"=M0, "M1"=M1, "M2"=M2, "grid_size_km"=grid_size_LL)
  if( Method %in% c("Mesh","Grid","Stream_network") ) GridList = list("M0"=M0, "M1"=M1, "M2"=M2, "grid_size_km"=grid_size_km)

  # Return
  Return = list("MeshList"=MeshList, "GridList"=GridList, "a_xl"=a_xl, "loc_i"=loc_i, "Kmeans"=Kmeans, "knot_i"=knot_i, "Method"=Method, "loc_x"=loc_x, "PolygonList"=PolygonList, "NN_Extrap"=PolygonList$NN_Extrap)
  return( Return )
}
