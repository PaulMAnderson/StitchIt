function varargout = stitcher(imStack,tileCoords,fusionWeight,maxPixelPos)
% Stitch one tile-scanned plane from one channel
%
% function stitchedPlane = stitcher(imStack,tileCoords,fusionWeight,maxPixelPos)
%
%
% Purpose
% This is the workhorse function that performs the stitching. All transformations,
% such as background subtraction, should already have been applied to the tile 
% data fed to this function. The image is stitched "backwards", which reduces
% photo-bleaching artifacts at tile overlap regions.
%
%
% Inputs
% imStack - the image stack
% tileCoords - pixel coordinates of each tile's top left pixel
% fusionWeight - a number between 0 and 1 indicating how the overlapping regions are averaged. 
%                0 means overlap with no blending. 1 means complete transparency in overlapping region.
%                if -1 we do **chessboard stitching**
%
% 
% Outputs
% stitchedPlane - the stitched image plane
% tilePositionInPixels - the position and size of each tile in the order they were laid down. 
%                        each row is: [x,xwidth,y,width]
%
%
% Rob Campbell - Basel 2014
%
% See also - stitchSection, stitchAllSections


if nargin<3
    %zero to 1. zero is no transparancy and 1 is 100% transparancy
    fusionWeight=0;
end

if nargin<4
    maxPixelPos=[];
end

if isempty(imStack)
    fprintf('%s: image stack is empty. Aborting.\n',mfilename)
    return
end


verbose = false;

userConfig=readStitchItINI;

%Flip arrays and stitch backwards. This reduces photo-bleaching artifacts.
imStack=flip(imStack,3);
tileCoords=flipud(tileCoords);

%Get rid of very, very high values as they are rubbish (the system *never* produces anything this large)
%and 2^16 will screw up the stitcher by clashing with the "marker" values (below). 
cutoffVal=2^16-500; %TODO -- hard-coded 
f=find(imStack > cutoffVal);
imStack(f)=cutoffVal;


%Now we can pre-allocate our image
tileSize=[size(imStack,1),size(imStack,2)];

% Determine the size of the final stitched image
projected_maxXpixel=max(tileCoords(:,2)+tileSize(2)+1);
projected_maxYpixel=max(tileCoords(:,1)+tileSize(1)+1);

if verbose
    fprintf('Projected max pixel -- X: %d Y: %d\n', projected_maxXpixel, projected_maxYpixel)
end

% In theory an integer number of tiles should always fit into each stitched plane. In auto-ROI acquisitions
% most planes will be bounded by empty pixels. For an unknown reason, however, sometimes the pre-allocated 
% image size is a few pixels short. StitchIt used to just not lay down the whole row or column of tiles in 
% such cases. This is a bit extreme, though, so "allowPartial" tiles lays these down then clips them to
% ensure that all sections have the same number of pixels. Probably there is no reason to set this to false
% other than for debugging.
allowPartialTiles = true;

if verbose && allowPartialTiles
    fprintf('%s.m is allowing partial tiles\n',mfilename)
end

if isempty(maxPixelPos)
    if verbose
        fprintf('variable maxPixelPos is empty. Using projected_maxXpixel=%d and projected_maxYpixel=%d instead\n',...
            projected_maxXpixel, projected_maxYpixel)
    end
    maxXpixel=projected_maxXpixel;
    maxYpixel=projected_maxYpixel;
    finalImSize = [maxYpixel,maxXpixel];
elseif ~allowPartialTiles
    maxXpixel = maxPixelPos(2);
    maxYpixel = maxPixelPos(1);

    if verbose
        fprintf('Min pixel from tile coords -- X: %d Y: %d\n', min(tileCoords(:,2)), min(tileCoords(:,1)))
        fprintf('Supplied max pixel from determineStitchedImageExtent -- X: %d Y: %d\n', maxXpixel, maxYpixel)
    end

    if projected_maxXpixel > maxXpixel
        fprintf('Warning, stage positions requested with projected max x pixel of %d but expected value is %d\n', ...
            projected_maxXpixel, maxXpixel);
    end
    if projected_maxYpixel > maxYpixel
        fprintf('Warning, stage positions requested with projected max y pixel of %d but expected value is %d\n', ...
            projected_maxYpixel, maxYpixel);
    end
    finalImSize = [maxYpixel,maxXpixel];
elseif allowPartialTiles
    if projected_maxXpixel>maxPixelPos(2)
        xMax = projected_maxXpixel;
    else
        xMax = maxPixelPos(2);
    end

    if projected_maxYpixel>maxPixelPos(1)
        yMax = projected_maxYpixel;
    else
        yMax = maxPixelPos(1);
    end

    finalImSize = [yMax,xMax];
    maxXpixel = maxPixelPos(2);
    maxYpixel = maxPixelPos(1);
end


%We will use the value 2^16 to indicate regions where a tile hasn't been placed.
%this is just a trick to make the tile fusion (which is currently just averaging) 
%work easily. Pre-allocate a little more than is needed (we'll trim it later).
% TODO -- this is not working right now. It's missing! We should just remove it, TBH





stitchedPlane = zeros(finalImSize, 'uint16');


if fusionWeight<0 %do chessboad
    stitchedPlane = repmat(stitchedPlane,[1,1,3]);
    chess=2; %needed for alternate tile placement
else
    chess=1; %places all tiles in the same layer
end

allocatedSize=size(stitchedPlane);

if verbose
    fprintf('stitched plane pre-allocated to %d pixel columns by %d pixel rows\n', fliplr(allocatedSize))
end


%Lay down the tiles

%Get stitching parameters
userConfig=readStitchItINI;

%We will store the position and size of each tile in case this is useful later
%e.g. for gradient-domain removal of tile seams
tilePositionInPixels=ones(size(imStack,3),4); %x,xwidth,y,ywidth

if verbose
    fprintf('\n%s.m reports -- Max X: %0.2f Max Y: %0.2f\n\n', mfilename, maxXpixel, maxYpixel)
end



for ii=1:size(imStack,3)

    %The indexes of the stitched image where we will be placing this tile
    xPos = [tileCoords(ii,2), tileCoords(ii,2)+tileSize(2)-1];
    yPos = [tileCoords(ii,1), tileCoords(ii,1)+tileSize(1)-1];
    tilePositionInPixels(ii,:) = [xPos(1),tileSize(2),yPos(1),tileSize(1)]; %this is stored to disk

    % Gracefully fail. In normal usage, the following conditions should never evaluate to true
    if yPos(1)<1
        fprintf('Y coordinate would place tile in position < 1. SKIPPING TILE\n')
        continue
    end

    if xPos(1)<1
        fprintf('X coordinate would place tile in position < 1. SKIPPING TILE\n')
        continue
    end

    if ~allowPartialTiles
        if yPos(2)>size(stitchedPlane,1)
            fprintf('Y coordinate would place tile up to pixel value %d but image is pre-allocated up to %d. SKIPPING TILE\n', ...
                yPos(2), size(stitchedPlane,1))
            continue
        end

        if xPos(2)>size(stitchedPlane,2)
            fprintf('X coordinate would place tile up to pixel value %d but image is pre-allocated up to %d. SKIPPING TILE\n', ...
                xPos(2), size(stitchedPlane,2))
            continue
        end
    end


    if verbose
       %fprintf('%d/%d Inserting tile at: x=%d to %d  y=%d to %d\n', ii, size(imStack,3), xPos,yPos)
    end

    %origTilePatch is the area where the tile will be placed. We store it in order to allow for
    %for "average" blending between one tile and another
    origTilePatch = stitchedPlane(yPos(1):yPos(2),xPos(1):xPos(2),mod(ii,chess)+1);

    newTile=imStack(:,:,ii);

    if fusionWeight>0 && ii>1 %Perform blending if needed
        %Make mask for blending
        bw=ones(size(origTilePatch),'int8');
        bw(origTilePatch < 2^16-1) = 0 ; %regions containing image data are zeroed

        maskOrig = single(bwdist(bw)); %Mask for already placed tile (time consuming!)
        maskOrig = maskOrig/max(maskOrig(:));
        maskNew = 1-maskOrig; %Mask for tile we are placing 

        %Create a blended tile using alpha-blending
        newTile = single(newTile).*maskNew + single(origTilePatch).*maskOrig;

        newTile = int16(newTile);
    end


    %Place tile into the area occupied by origTilePatch
    stitchedPlane(yPos(1):yPos(2),xPos(1):xPos(2),mod(ii,chess)+1) = newTile;


    %Incorporate debug info text into image for each tile if we're chessboard stitching. 
    %This indictes the tile index and X/Y grid position. 
    if fusionWeight<0
        pos = [yPos(1),xPos(2)]; %Where the text will go
        pos = round(pos + tileSize*0.12);
        txt = sprintf('#%d',ii);
        %For some reason we don't get the text overlay onto a black background on alternate rows. 
        %But this isn't that important, TBH. 
        stitchedPlane = rendertext(stitchedPlane,txt,[255,255,255], pos,...
                        'ovr',[],allocatedSize(1:2));
    end


end %for ii=1:size(imStack,3)

if allowPartialTiles && ~isempty(maxPixelPos)
    stitchedPlane = stitchedPlane(1:maxPixelPos(1), 1:maxPixelPos(2));
end

%If the matrix has grown, we have a problem with the way pre-allocation is being done. 
if any(size(stitchedPlane)>allocatedSize)
    fprintf(['Warning: stitched image has grown during stitching from pre-allocated size\n', ...
             'Was %d by %d, now %d by %d\n'], allocatedSize, size(stitchedPlane))
end

if verbose
    fprintf('stitcher produced a stitched plane of size %d by %d\n',size(stitchedPlane))
end

%Flip or rotate sections if needed.
st=userConfig.stitching;
if st.flipud
    stitchedPlane=flipud(stitchedPlane);
    tilePositionInPixels(:,3)=abs(tilePositionInPixels(:,3)-max(tilePositionInPixels(:,3)))+1;
end

if st.fliplr
    stitchedPlane=fliplr(stitchedPlane);
    tilePositionInPixels(:,1)=abs(tilePositionInPixels(:,1)-max(tilePositionInPixels(:,1)))+1;
end

if st.rotate ~= 0
    stitchedPlane=rot90(stitchedPlane,st.rotate);
    %TODO - return the tilePositionInPixels
end


%Handle output arguments
if nargout>0
      varargout{1}=stitchedPlane;
end

if nargout>1
    varargout{2}=tilePositionInPixels;
end
