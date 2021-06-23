function out = determineStitchedImageExtent
    % Determine the size of the stitched images when stitching using tile positions
    %
    %
    % Purpose
    % When sitching using tile positions, individual sections may have slightly different sizes. 
    % With auto-ROI the sections will be very different sizes. In order to produces a series of
    % stitched images having the same size from section to section we need to determine the 
    % locations of all the tiles in the whole sample and find the extrema in the x/y plane. 
    % This function does this. 
    %
    % Inputs - none. just run from sample directory
    %
    % Outputs - 
    % out - a structure with the extrema
    %
    %
    % Rob Campbell - SWC 2020


    verbose=0; %report to screen lots on info on 
    plotboxes=0; %make a plot with the imaged areas overlain

    if verbose
        fprintf('%s is determining the extent of the imaged area\n', mfilename)
    end

    out=[];
    [data,successfulRead]=readMetaData2Stitchit;

    if ~successfulRead
        fprintf('Failed to find acquisition in current directory\n')
        return
    end

    %Load the INI file and extract default values from it
    userConfig=readStitchItINI;

    % Ensure we choose the correct rows for theoretical vs actual coords
    if userConfig.stitching.doStageCoords
        colInds = [5,6];
    else
        colInds = [3,4];
    end

    if ~exist(userConfig.subdir.rawDataDir, 'dir')
        fprintf('Found no raw data directory\n')
        return
    end

    rDataDirs = dir(fullfile(userConfig.subdir.rawDataDir,[directoryBaseName,'*']));

    % Pre-allocate
    out.minXPos = nan(1,length(rDataDirs));
    out.minYPos = nan(1,length(rDataDirs));
    out.maxXPos = nan(1,length(rDataDirs));
    out.maxYPos = nan(1,length(rDataDirs));

    tp = {}; %cache all loaded position arrays in case we want to do stuff with them later
    for ii=1:length(rDataDirs)
        posFname = fullfile(userConfig.subdir.rawDataDir,rDataDirs(ii).name,'tilePositions.mat');
        if ~exist(posFname,'file')
            continue
        end

        load(posFname,'positionArray')
        tp{ii} = positionArray;

        % Log the actual minimum X and Y positions
        % TODO - we should maybe allow for predicted stage positions instead of actual
        out.minXPos(ii)=min(positionArray(:,colInds(1)));
        out.minYPos(ii)=min(positionArray(:,colInds(2)));

        out.maxXPos(ii)=max(positionArray(:,colInds(1)));
        out.maxYPos(ii)=max(positionArray(:,colInds(2)));

        if verbose
            fprintf('%d/%d Front/Left -- x=%0.2f  y=%0.2f (%d by %d tiles)\n', ...
                ii, ...
                length(rDataDirs), ...
                out.maxXPos(ii), ...
                out.maxYPos(ii), ...
                length(unique(positionArray(:,1))), ...
                length(unique(positionArray(:,2))) )
        end

    end


    % Ensure we choose the longest position array from which 
    [~,indLongest]=max(cellfun(@length,tp));

    % The tile step size is the distance moved by the microscope in mm as it travels from one x/y stage
    % location to the next. It is equal to the tile size (image FOV) minus the overlap between tiles.
    posDataCols = tp{indLongest}(:,3:4); %Both x and y because we don't know which direction is the dominant tiling direction
    tileStepSizeMM = abs(mode(diff( posDataCols )));
    tileStepSizeMM = max(tileStepSizeMM); % To use axis where most motions happen

    if tileStepSizeMM<=0
        fprintf('WARNING %s calculates a tile step size of less than equal to zero: %0.1f. This is WRONG!\n', ...
            mfilename, tileStepSizeMM)
    end

    % The tile extent in mm is the image FOV
    tileExtentInMM = tileStepSizeMM  / (1-data.mosaic.overlapProportion);

    % The number of mm of overlap between adjacent tiles
    tileOverlapInMM = tileExtentInMM - tileStepSizeMM;

    out.minXY = [min(out.minXPos), min(out.minYPos)] - tileExtentInMM* (1-userConfig.tile.cropProportion);

    out.maxXY = [max(out.maxXPos), max(out.maxYPos)]; % This is the "origin" front/left


    % This is a call to a test function to ensure that all is running as expected
    %checkMinMax

    if plotboxes
        % Use the minimum x/y position and the tile position array to produce pixel positions for
        % where the tiles ought to go. 
        voxSize = [data.voxelSize.X, data.voxelSize.Y];
        tileStep = [(tileStepSizeMM*1E3) / voxSize(1), (tileStepSizeMM*1E3) / voxSize(2)];
        tileSizeInPixels = [(tileExtentInMM*1E3) / voxSize(1), (tileExtentInMM*1E3) / voxSize(2)];
        figure(4592)
        clf
        hold on
        jj = jet(length(rDataDirs));
        for ii=1:length(rDataDirs)

            tmp=stagePos2PixelPos(tp{ii}(:,colInds), voxSize, out.maxXY);
            minPix = min(tmp);
            maxPix = max(tmp) + tileSizeInPixels;
            d = maxPix-minPix; % This is the size of the box

            % Plot the box
            x = [minPix(2), minPix(2), minPix(2)+d(2), minPix(2)+d(2), minPix(2)];
            y = [minPix(1), minPix(1)+d(1), minPix(1)+d(1), minPix(1), minPix(1)];
            plot(x, y, '-', 'Color', jj(ii,:), 'LineWidth', 2)

            % Print to screen the size and location of the box
            fprintf('%d/%d %dx%d pixels. Far corner at pixel pos %d/%d; min pixel: %d/%d, (%0.2f by %0.2f tile steps).\n', ...
                ii, length(rDataDirs), ...
                ceil(d),  ...
                ceil(max(x)), ceil(max(y)), ...
                ceil(min(x)), ceil(min(y)), ...
                d(1)/tileStep(1), d(2)/tileStep(2))
        end
        hold off
        axis ij

        % summary
        fprintf('\nThe above was determined with:\n')
        fprintf('voxelSize: Y: %0.3f X: %0.3f \n', voxSize)
        fprintf('Tile step size in mm: %0.3f \n\n', tileStepSizeMM)

    end




    function checkMinMax
        % This is somewhat of a test function. If the min and max positions we have extracted are all
        % correct, we should fit an integer number of tiles into the space they demarcate for each section.
        fprintf('Do the min/max stage coords results in an integer number of tiles?\n')

        for ii = 1:length(out.minYPos)

            % If we just do the following we will be num tiles minus 1 because it does not
            % take into account the area imaged by the final tile row and tile column.
            dX = out.maxXPos(ii) - out.minXPos(ii);
            dY = out.maxYPos(ii) - out.minYPos(ii);

            % Therefore we add one tile step size (tile FOV minus the overlap)
            dX = out.maxXPos(ii) - out.minXPos(ii) + tileStepSizeMM;
            dY = out.maxYPos(ii) - out.minYPos(ii) + tileStepSizeMM;
            fprintf('%d/%d. Tiles plus on step size: %0.1f x %0.1f\n', ...
                ii, length(out.minYPos), ...
                dX/tileStepSizeMM, dY/tileStepSizeMM)

        end
    end %checkMinMax


end % Main enclosing function

