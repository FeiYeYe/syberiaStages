#' Import data stage for Syberia model process.
#'
#' @param import_options list. The available import options. Will differ
#'    depending on the adapter. (default is file adapter)
#' @export
import_stage <- function(import_options) {
  if (!is.list(import_options)) # Coerce to a list using the default adapter
    import_options <- setNames(list(resource = import_options), default_adapter())

  build_import_stagerunner(import_options)
}


#' Fetch the default adapter keyword from the active syberia
#' project's configuration file.
#'
#' @return a string representing the default adapter.
default_adapter <- function() {
  # TODO: (RK) Multi-syberia projects root tracking?

  # Grab the default adapter if it is not provided from the Syberia
  # project's configuration file. If no default is specified there,
  # we will assume we're reading from a file.
  default_adapter <- syberia_config()$default_adapter %||% 'file'
}

#' Build a stagerunner for importing data with backup sources.
#'
#' @param import_options list. Nested list, one adapter per list entry.
#'   These adapter parametrizations will get converted to legitimate
#'   IO adapters. (See the "adapter" reference class.)
build_import_stagerunner <- function(import_options) {
  stages <- lapply(seq_along(import_options), function(index) {
    stage <- function(modelenv) {
      # Only run if data isn't already loaded
      if (!'data' %in% ls(modelenv)) {
        attempt <- suppressWarnings(suppressMessages(
          tryCatch(adapter$read(opts), error = function(e) FALSE)))
      }
    }

    # Now attach the adapter and options to the above closure.
    adapter <- names(import_options)[index] %||% default_adapter()
    environment(stage)$adapter <- fetch_adapter(adapter)
    environment(stage)$opts <- import_options[[index]]
    stage
  })
  names(stages) <- vapply(stages, function(stage)
    paste0("Import from ", environment(stage)$adapter), character(1))

  # Always verify the data was loaded correctly in a separate stageRunner step.
  stages[[length(stages) + 1]] <- function(modelenv) {
    if (!'data' %in% ls(modelenv))
      stop("Failed to load data from all data sources")
    
    # TODO: (RK) Move this somewhere else.
    modelenv$import_stage$variable_summaries <-
      statsUtils::variable_summaries(modelenv$data) 
  }
  names(stages)[length(stages)] <- "(Internal) Verify data was loaded" 

  stages
}

#' Fetch an import adapter.
#'
#' @param keyword character. The keyword for the adapter (e.g., 'file', 's3', etc.)
#' @return an \code{adapter} object (defined in this package, syberiaStages)
fetch_adapter <- function(keyword) {
  adapters <- syberiaStructure:::get_cache('adapters')
  if (!is.element(keyword, names(adapters))) {
  } else {
    # TODO: (RK) Should we re-compile the adapter if the syberia config
    # changed, or force the user to restart R/syberia?
    adapters[[keyword]]
  }
}

#' A helper function for formatting parameters for adapters to
#' correctly include an argument "file", with aliases
#' "resource", "filename", "name", and "path".
#' @return the fixed and sanitized formatted options.
common_file_formatter <- function(opts) {
  if (!is.element('resource', names(opts))) {
    filename <- opts$file %||% opts$filename %||% opts$name %||% opts$path
    if (is.null(filename))
      stop("You are trying to read from ", sQuote(.keyword), ", but you did ",
           "not provide a file name.", call. = FALSE)
    opts$resource <- filename
  }
  if (!is.character(opts$resource))
    stop("You are trying to read from ", sQuote(.keyword), ", but you provided ",
         "a filename of type ", sQuote(class(opts$resource)[1]), " instead of ",
         "a string. Make sure you are passing a file name ",
         "(for example, 'example/file.csv')", call. = FALSE)
  opts
}

#' Construct a file adapter.
#'
#' @return an \code{adapter} object which reads and writes to a file.
construct_file_adapter <- function() {
  read_function <- function(opts) {
    # If the user provided any of the options below in their syberia model,
    # pass them along to read.csv
    read_csv_params <- c('header', 'sep', 'quote', 'dec', 'fill', 'comment.char',
                         'stringsAsFactors')
    args <- list_merge(list(file = opts$resource, stringsAsFactors = FALSE),
                       opts[read_csv_params])
    do.call(read.csv, args)
  }

  write_function <- function(object, opts) {
    # If the user provided any of the options below in their syberia model,
    # pass them along to write.csv
    write_csv_params <- setdiff(names(formals(write.table)), c('x', 'file'))
    args <- list_merge(
      list(x = object, file = opts$resource, row.names = FALSE),
      opts[write_csv_params])
    do.call(write.csv, args)
  }

  # TODO: (RK) Read default_options in from config, so a user can
  # specify default options for various adapters.
  adapter(read_function, write_function, format_function = common_file_formatter,
          default_options = list(), keyword = 'file')
}

#' Construct an Amazon Web Services S3 adapter.
#'
#' This requires that the user has set up the s3mpi package to
#' work correctly (for example, the s3mpi.path option should be set).
#' (Note that this adapter is not related to R's S3 classes).
#'
#' @return an \code{adapter} object which reads and writes to Amazon's S3.
construct_s3_adapter <- function() {
  load_s3mpi_package <- function() {
    if (!'s3mpi' %in% installed.packages())
      stop("You must install and set up the s3mpi package from ",
           "https://github.com/robertzk/s3mpi", call. = FALSE)
    require(s3mpi)
  }

  read_function <- function(opts) {
    load_s3mpi_package()

    # If the user provided an s3 path, like "s3://somebucket/some/path/", 
    # pass it along to the s3read function.
    args <- list(name = opts$resource)
    if (is.element('s3path', names(opts))) args$.path <- opts$s3path
    do.call(s3mpi::s3read, args)
  }

  write_function <- function(object, opts) {
    load_s3mpi_package()

    # If the user provided an s3 path, like "s3://somebucket/some/path/", 
    # pass it along to the s3read function.
    args <- list(obj = object, name = opts$resource)
    if (is.element('s3path', names(opts))) args$.path <- opts$s3path
    do.call(s3mpi::s3read, args)
  }

  # TODO: (RK) Read default_options in from config, so a user can
  # specify default options for various adapters.
  adapter(read_function, write_function, formatter, list(), keyword = 's3')
}

# A reference class to abstract importing and exporting data.
adapter <- setRefClass('adapter',
  list(.read_function = 'function', .write_function = 'function',
       .format_options = 'function', .default_options = 'list', .keyword = 'character'),
  methods = list(
    initialize = function(read_function, write_function,
                          format_options = identity, default_options = list(),
                          keyword = character(0)) { 
      .read_function <<- read_function
      .write_function <<- write_function
      .format_options <<- format_options
      .default_options <<- default_options
      .keyword <<- keyword
    },

    read = function(options = list()) {
      .read_function(format_options(options))
    },

    write = function(value, options = list()) {
      .write_function(value, ormat_options(options))
    },

    format_options = function(options) {
      if (!is.list(options)) options <- list(resource = options)

      # Merge in default options if they have not been set.
      for (i in seq_along(.default_options))
        if (!is.element(name <- names(.default_options)[i], names(options)))
          options[[name]] <- .default_options[[i]]

      .format_options(options)
    }
  )
)

