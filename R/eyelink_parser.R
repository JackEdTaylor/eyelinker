
##' Read EyeLink ASC file
##'
##' ASC files contain raw data from EyeLink eyetrackers (they're ASCII versions of the raw binaries which are themselves in EDF format). 
##' This utility tries to parse the data into something that's usable in R. Please read the EyeLink manual before using it for any serious work, very few checks are done to see if the output makes sense. 
##' read.asc will return data frames containing a "raw" signal as well as event series. Events are either system signals (triggers etc.), which are stored in the "msg" field, or correspond to the Eyelink's interpretation of the eye movement traces (fixations, saccades, blinks). 
##' ASC files are divided into blocks signaled by START and END signals. The block structure is reflected in the "block" field of the dataframes.
##' If all you have is an EDF file, you need to convert it first using edf2asc from the Eyelink toolbox.
##' The names of the various columns are the same as the ones used in the Eyelink manual, with two exceptions. "cr.info", which doesn't have a name in the manual, gives you information about corneal reflection tracking. If all goes well its value is just "..."
##' "remote.info" gives you information about the state of the remote setup, if applicable. It should also be just a bunch of ... values. Refer to the manual for details. 
##' @title Read EyeLink ASC file
##' @param fname file name
##' @return a list with components
##' raw: raw eye positions, velocities, resolution, etc.
##' msg: messages (no attempt is made to parse them)
##' fix: fixations
##' blinks: blinks
##' sacc: saccades
##' info: meta-data
##' 
##' @author Simon Barthelme
##' @examples
##' #Example file from SR research that ships with the package
##' fpath <- system.file("extdata/mono500.asc.gz",package="eyelinker")
##' dat <- read.asc(fpath)
##' plot(dat$raw$time,dat$raw$xp,xlab="Time (ms)",ylab="Eye position along x axis (pix)")
##' @export
read.asc <- function(fname)
{
    inp <- readLines(fname)

    #Convert to ASCII
    inp <- stri_enc_toascii(inp)
    
    #Filter out empty lines, comments, trailing whitespace
    inp <- str_select(inp,"^\\w*$",reverse=TRUE) %>% str_select("^#",reverse=TRUE) %>% str_select("^/",reverse=TRUE) %>% str_trim(side="right")

    #Read meta-data from the "SAMPLES" line
    info <- getInfo(inp)
    has.raw <- !is.na(info)
    
    #Just to spite us, there's an inconsistency in how HTARG info is encoded (missing tab)
    #We fix it if necessary
    if (all(has.raw) && info$htarg)
    {
        inp <- str_replace_all(inp,fixed("............."),fixed("\t............."))
    }
    
    #"Header" isn't strict, it's whatever comes before the first "START" line
    init <- str_detect(inp,"^START") %>% which %>% min
    header <- inp[1:(init-1)]
    #inp <- inp[init:length(inp)]
    
    #Find blocks
    bl.start <- str_detect(inp,"^MSG.*TRIALID")%>%which
    cat(sprintf(" - %i TRIALIDs detected\n", length(bl.start)))
    bl.end <- str_detect(inp,"^MSG.*TRIAL_RESULT")%>%which
    cat(sprintf(" - %i TRIAL_RESULTs detected\n", length(bl.end)))
    
    # exclude trials that start but never end
    inp_relevant <- inp[c(bl.start, bl.end)] %>% sort()  # get start and end MSGs and sort by time
    if (length(bl.start) > length(bl.end)) {
      dodgy_trialids <- inp_relevant[sapply(1:length(inp_relevant), function(i) {
        # extract trials which started and never ended
        str_detect(inp_relevant[i], "^MSG.*TRIALID") & !str_detect(inp_relevant[i+1], "^MSG.*TRIAL_RESULT")
      })]
      inp <- inp[!inp %in% dodgy_trialids]  # exclude these bad trials
      bl.start <- str_detect(inp,"^MSG.*TRIALID")%>%which
      bl.end <- str_detect(inp,"^MSG.*TRIAL_RESULT")%>%which
      cat(sprintf(" - %i unending trials ignored\n", length(dodgy_trialids)))
    }
    
    nBlocks <- length(bl.start)
    blocks <- llply(1:nBlocks,function(indB) process.block(inp[bl.start[indB]:bl.end[indB]],info))
    ## collect <- function(vname)
    ##     {
    ##         valid <- Filter(function(ind) !is.null(blocks[[ind]][[vname]]),1:length(blocks))
    ##         ldply(valid,function(ind) mutate(blocks[[ind]][[vname]],block=ind))
    ##     }
    collect <- function(vname)
    {
        #Merge the data from all the different blocks
        out <- suppressWarnings(try(map(blocks,vname) %>% compact %>% map_df(identity,.id="block") ,TRUE))
        if (is(out,"try-error"))
        {
            sprintf("Failed to merge %s",vname) %>% warning
            #Merging has failed, return as list
            map(blocks,vname)
        }
        else
        {
            out
        }
    }
    vars <- c("raw","msg","sacc","fix","blinks","info","trialIDs")
    #Collect all the data across blocks
    out <- map(vars,collect) %>% setNames(vars)

    out$info <- info
    out$trialIDs <- str_replace(inp[bl.start], "^MSG.*TRIALID ", "")
    out$raw$trialID <- out$trialIDs[as.numeric(out$raw$block)]
    out$msg$trialID <- out$trialIDs[as.numeric(out$msg$block)]
    out$sacc$trialID <- out$trialIDs[as.numeric(out$sacc$block)]
    out$fix$trialID <- out$trialIDs[as.numeric(out$fix$block)]
    out$blinks$trialID <- out$trialIDs[as.numeric(out$blinks$block)]
    out
}



process.block.header <- function(blk)
{
    endh <- str_detect(blk,'^SAMPLES') %>% which
    has.samples <- TRUE
    #if raw data is missing, then no SAMPLES line
    if (length(endh)!=1)
    {
        endh <- str_detect(blk,'^EVENTS') %>% which
        has.samples <- FALSE
    }
    hd <-blk[1:endh]
    #Parse  the EVENTS line 
    ev <- str_select(hd,"^EVENTS")
    regex.num <- "([-+]?[0-9]*\\.?[0-9]+)"
    srate <-str_match(ev,paste0("RATE\t",regex.num))[,2] %>% as.numeric
    tracking <-str_match(ev,"TRACKING\t(\\w+)")[,2]
    filter <- str_match(ev,"FILTER\t(\\d)")[,2] %>% as.numeric
    events <- list(left=str_detect(ev,fixed("LEFT")),
                   right=str_detect(ev,fixed("RIGHT")),
                   res=str_detect(ev,fixed(" RES ")),
                   tracking=tracking,
                   srate=srate,
                   filter=filter)

    if (!has.samples)
    {
        samples <- NULL
    }
    else
    {
        #Now do the same thing for the SAMPLES line
        sm <- str_select(hd,"^SAMPLES")
        
        srate <-str_match(sm,paste0("RATE\t",regex.num))[,2] %>% as.numeric
        tracking <-str_match(sm,"TRACKING\t(\\w+)")[,2]
        filter <- str_match(sm,"FILTER\t(\\d)")[,2] %>% as.numeric

        samples <- list(left=str_detect(sm,fixed("LEFT")),
                    right=str_detect(sm,fixed("RIGHT")),
                    res=str_detect(ev,fixed(" RES ")),
                    vel=str_detect(ev,fixed(" VEL ")),
                    tracking=tracking,
                    srate=srate,
                    filter=filter)
    }
    list(events=events,samples=samples,the.rest=blk[-(endh-1:endh)])
}

#Turn a list of strings with tab-separated field into a data.frame
tsv2df <- function(dat,coltypes)
{
    if (length(dat)==1)
    {
        dat <- paste0(dat,"\n")
    }
    else
    {
        dat <- paste0(dat,collapse="\n")
    }
    out <- read_tsv(dat,col_names=FALSE,col_types=paste0(coltypes,collapse=""))
    ##        if (!(is.null(attr(suppressWarnings(out), "problems")))) browser()
    out
}

parse.saccades <- function(evt,events)
{
    #Focus only on EFIX events, they contain all the info
    esac <- str_select(evt,"^ESAC") %>% str_replace("ESACC\\s+(R|L)","\\1\t") %>% str_replace_all("\t\\s+","\t")  
    #Missing data
    esac <- str_replace_all(esac,"\\s\\.","\tNA")

    df <- str_split(esac,"\n") %>% ldply(function(v) { str_split(v,"\\t")[[1]] })
    #Get a data.frame
    if (ncol(df)==10)
    {
        #ESACC  <eye>  <stime>  <etime>  <dur> <sxp>  <syp>  <exp>  <eyp>  <ampl> <pv> 
        names(df) <- c("eye","stime","etime","dur","sxp","syp","exp","eyp","ampl","pv")
        
    }
    else if (ncol(df)==12)
    {
        names(df) <- c("eye","stime","etime","dur","sxp","syp","exp","eyp","ampl","pv","xr","yr")
    }
    
    dfc <- suppressWarnings(llply(as.list(df)[-1],as.numeric) %>% as.data.frame )
    dfc$eye <- df$eye
    dfc
}



parse.blinks <- function(evt,events)
{
    eblk <- str_select(evt,"^EBLINK") %>% str_replace("EBLINK\\s+(R|L)","\\1\t") %>% str_replace_all("\t\\s+","\t") 
    #Get a data.frame
    #eblk <- eblk %>% tsv2df
    df <- str_split(eblk,"\n") %>% ldply(function(v) { str_split(v,"\\t")[[1]] })
    names(df) <- c("eye","stime","etime","dur")
    dfc <- suppressWarnings(llply(as.list(df)[-1],as.numeric) %>% as.data.frame )
    dfc$eye <- df$eye
    dfc
}



parse.fixations <- function(evt,events)
{
    #Focus only on EFIX events, they contain all the info
    efix <- str_select(evt,"^EFIX") %>% str_replace("EFIX\\s+(R|L)","\\1\t") %>% str_replace_all("\t\\s+","\t") 
    #Get a data.frame
    #efix <- efix %>% tsv2df
    df <- str_split(efix,"\n") %>% ldply(function(v) { str_split(v,"\\t")[[1]] })
    if (ncol(df)==7)
    {
        names(df) <- c("eye","stime","etime","dur","axp","ayp","aps")
    }
    else if (ncol(df)==9)
    {
        names(df) <- c("eye","stime","etime","dur","axp","ayp","aps","xr","yr")
    }
    dfc <- suppressWarnings(llply(as.list(df)[-1],as.numeric) %>% as.data.frame )
    dfc$eye <- df$eye
    dfc
}

#evt is raw text, events is a structure with meta-data from the START field
process.events <- function(evt,events)
{
    #Messages
    if (any(str_detect(evt,"^MSG")))
    {
        msg <- str_select(evt,"^MSG") %>% str_sub(start=5) %>% str_match("(\\d+)\\s(.*)") 
        msg <- data.frame(time=as.numeric(msg[,2]),text=msg[,3])
    }
    else
    {
        msg <- c()
    }
    
    fix <- if (str_detect(evt,"^EFIX") %>% any) parse.fixations(evt,events) else NULL
    sacc <- if (str_detect(evt,"^ESAC") %>% any) parse.saccades(evt,events) else NULL
    blinks <- if (str_detect(evt,"^SBLI") %>% any) parse.blinks(evt,events) else NULL
    list(fix=fix,sacc=sacc,msg=msg,blinks=blinks)
}


#A block is whatever one finds between a START and an END event
process.block <- function(blk,info)
{
    hd <- process.block.header(blk)
    blk <- hd$the.rest
    if (all(is.na(info))) #no raw data
    {
        raw <- NULL
        which.raw <- rep(FALSE,length(blk))
    }
    else
    {
        colinfo <- coln.raw(info)
        
        raw.colnames <- colinfo$names
        raw.coltypes <- colinfo$types
        
        #Get the raw data (lines beginning with a number)
        which.raw <- str_detect(blk,'^\\d')
        raw <- blk[which.raw] %>% str_select('^\\d') # %>% str_replace(fixed("\t..."),"")
        #        raw <- str_replace(raw,"\\.+$","")
        
        #Filter out all the lines where eye position is missing, they're pointless and stored in an inconsistent manner
        iscrap <- str_detect(raw, "\\s+\\.\\s+\\.\\s+")
        crap <- raw[iscrap]
        raw <- raw[!iscrap]
        if (length(raw)>0) #We have some data left
        {
            
            #Turn into data.frame
            raw <- tsv2df(raw,raw.coltypes)
            if (ncol(raw) == length(raw.colnames))
            {
                names(raw) <- raw.colnames
            }
            else
            {
                warning("Unknown columns in raw data. Assuming first one is time, please check the others")
                #names(raw)[1:length(raw.colnames)] <- raw.colnames
                names(raw)[1] <- "time"
            }
            nCol <- ncol(raw)
            if (any(iscrap))
            {
                crapmat <- matrix(NA,length(crap),nCol)
                crapmat[,1] <- as.numeric(str_match(crap,"^(\\d+)")[,1])
                crapmat <- as.data.frame(crapmat)
                names(crapmat) <- names(raw)
                raw <- rbind(raw,crapmat)
                raw <- raw[order(raw$time),]
            }
        }
        else
        {
            warning("All data are missing in current block")
            raw <- NULL
        }
    }
    #The events (lines not beginning with a number)
    evt <- blk[!which.raw]
    res <- process.events(evt,hd$events)
    res$raw <- raw
    res$sampling.rate <- hd$events$srate
    res$left.eye <- hd$events$left
    res$right.eye <- hd$events$right
    res
}

#Read some meta-data from the SAMPLES line
#Inspired by similar code from cili library by Ben Acland
getInfo <- function(inp)
{
    info <- list()
    #Find the "SAMPLES" line
    l <- str_select(inp,"^SAMPLES")
    if (length(l)>0)
    {
        l <- l[[1]]
        info$velocity <- str_detect(l,fixed("VEL"))
        info$resolution <- str_detect(l,fixed("RES"))
        #Even in remote setups, the target information may not be recorded 
        #e.g.: binoRemote250.asc
        #so we make sure it actually is
        info$htarg <- FALSE
        if (str_detect(l,fixed("HTARG")))
        {
            #Normally the htarg stuff is just twelve dots in a row, but in case there are errors we need
            #the following regexp.
            pat <- "(M|\\.)(A|\\.)(N|\\.)(C|\\.)(F|\\.)(T|\\.)(B|\\.)(L|\\.)(R|\\.)(T|\\.)(B|\\.)(L|\\.)(R|\\.)"
            info$htarg <- str_detect(inp,pat) %>% any
        }
        info$input <- str_detect(l,fixed("INPUT"))
        info$left <- str_detect(l,fixed("LEFT"))
        info$right <- str_detect(l,fixed("RIGHT"))
        info$cr <- str_detect(l,fixed("CR"))
        info$mono <- !(info$right & info$left)
    }
    else #NO SAMPLES!!!
    {
        info <- NA
    }
    info
}

#Column names for the raw data
coln.raw <- function(info)
{
    eyev <- c("xp","yp","ps")
    ctype <- rep("d",3)
    if (info$velocity)
    {
        eyev <- c(eyev,"xv","yv")
        ctype <- c(ctype,rep("d",2))
    }
    if (info$resolution)
    {
        eyev <- c(eyev,"xr","yr")
        ctype <- c(ctype,rep("d",2))
    }

    if (!info$mono)
    {
        eyev <- c(paste0(eyev,"l"),paste0(eyev,"r"))
        ctype <- rep(ctype,2)
    }

    #With corneal reflections we need an extra column
    if (info$cr)
    {
        eyev <- c(eyev,"cr.info")
        ctype <- c(ctype,"c")
    }

    #Three extra columns for remote set-up
    if (info$htarg)
    {
        eyev <- c(eyev,"tx","ty","td","remote.info")
        ctype <- c(ctype,c("d","d","d","c"))
    }
    
    
    list(names=c("time",eyev),types=c("i",ctype))
}
