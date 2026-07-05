%% New2.m — Complete Incense-Stick Turbulent-Flow Analysis
% Single-file MATLAB workflow: video -> optical flow -> turbulence statistics
% -> plots -> GIFs -> CSV/MAT outputs.
%
% IMPORTANT PHYSICAL NOTE
% Optical flow measures apparent image-pattern motion. It becomes a physical
% gas velocity only after a valid spatial calibration (metres/pixel), correct
% frame timing, suitable image seeding/contrast, and experimental validation.
% The 2-D TKE reported here is 0.5*(u'^2+v'^2) and excludes the out-of-plane
% velocity component.
%
% Required toolboxes/functions:
%   - Computer Vision Toolbox: opticalFlowFarneback, estimateFlow
%   - Image Processing Toolbox: imshow, imagesc support
%   - Signal Processing Toolbox: xcorr, pwelch
%   - Statistics and Machine Learning Toolbox: skewness, kurtosis
%
% Keep this file and AP.mp4 in the same folder, or select the video when asked.

clear; close all; clc;

%% ========================================================================
% 1. USER SETTINGS — EDIT ONLY THIS SECTION WHEN NEEDED
% =========================================================================
cfg.videoFile = 'AP.mp4';
cfg.outputFolder = 'New2_results';
cfg.addTimestampToOutput = true;

% Sampling
cfg.desiredSamples = 1000;       % Approximate number of sampled video frames
cfg.startFrame = 1;              % First original video frame to consider
cfg.endFrame = inf;              % Use inf for the complete video

% Probe coordinates: [x_pixel, y_pixel]
cfg.probePoints = [
    130, 200;
    180, 200;
    230, 200;
    280, 200;
    330, 200;
    380, 200;
    430, 200;
    480, 200
];
cfg.probeHalfWindow = 2;         % 2 gives a 5x5 local averaging window

% Spatial calibration
% Existing project assumption: 10 px = 1 mm -> 1e-4 m/px.
% VERIFY this value from a known object in YOUR video before using SI results.
cfg.metersPerPixel = 1.0e-4;
% Set cfg.metersPerPixel = NaN to save results in pixels/s instead of m/s.

% Fluid / buoyancy parameters — verify for the actual experiment
cfg.kinematicViscosity = 1.5e-5; % air, m^2/s
cfg.rhoAmbient = 1.20;           % kg/m^3
cfg.rhoPlume = 1.06;             % kg/m^3, project assumption
cfg.gravity = 9.81;              % m/s^2
cfg.referenceLength_m = 0.013;   % 13 mm; verify the intended characteristic length

% Plume-width analysis
cfg.enablePlumeWidth = true;
cfg.plumeYPositions = [];        % [] -> automatically choose 12 horizontal rows
cfg.plumePolarity = 'bright';    % 'bright', 'dark', or 'auto'
cfg.plumeThresholdSigma = 0.50;  % threshold = median +/- factor*robust sigma
cfg.minimumPlumeRunPixels = 5;
cfg.profileSmoothingPixels = 7;

% GIF / optional MP4 diagnostics
cfg.makeDiagnosticGIF = true;
cfg.makePlumeGIF = true;
cfg.makeDiagnosticMP4 = false;
cfg.maxGifFrames = 80;
cfg.gifDelaySeconds = 0.10;
cfg.quiverStepPixels = 16;

% Plot and analysis settings
cfg.figureVisible = 'off';       % 'on' to display every result figure
cfg.saveMATLABFigures = true;    % Also save editable .fig files
cfg.maxCorrelationLagSeconds = 2.0;
cfg.psdProbe = 4;                % Probe used for the detailed PSD/PDF plots
cfg.pdfBins = 40;
cfg.saveResolutionDPI = 300;

%% ========================================================================
% 2. PROJECT PATHS AND INPUT VALIDATION
% =========================================================================
scriptPath = mfilename('fullpath');
if isempty(scriptPath)
    projectDir = pwd;
else
    projectDir = fileparts(scriptPath);
end

videoPath = fullfile(projectDir, cfg.videoFile);
if ~isfile(videoPath)
    [selectedFile, selectedPath] = uigetfile( ...
        {'*.mp4;*.MP4;*.avi;*.AVI;*.mov;*.MOV', 'Video files'}, ...
        'Select the incense-stick video');
    if isequal(selectedFile, 0)
        error('Video file was not found and no replacement file was selected.');
    end
    videoPath = fullfile(selectedPath, selectedFile);
    cfg.videoFile = selectedFile;
end

if exist('opticalFlowFarneback', 'class') ~= 8 && exist('opticalFlowFarneback', 'file') ~= 2
    error(['opticalFlowFarneback is unavailable. Install/enable the ', ...
           'Computer Vision Toolbox.']);
end
if exist('xcorr', 'file') ~= 2 || exist('pwelch', 'file') ~= 2
    error('xcorr and pwelch are required from the Signal Processing Toolbox.');
end

if cfg.addTimestampToOutput
    runStamp = datestr(now, 'yyyymmdd_HHMMSS');
    outputDir = fullfile(projectDir, [cfg.outputFolder '_' runStamp]);
else
    outputDir = fullfile(projectDir, cfg.outputFolder);
end
figDir = fullfile(outputDir, 'figures');
gifDir = fullfile(outputDir, 'gifs');
dataDir = fullfile(outputDir, 'data');
mkdirIfNeeded(outputDir);
mkdirIfNeeded(figDir);
mkdirIfNeeded(gifDir);
mkdirIfNeeded(dataDir);

fprintf('\n============================================================\n');
fprintf('NEW2 COMPLETE TURBULENCE ANALYSIS\n');
fprintf('Video  : %s\n', videoPath);
fprintf('Output : %s\n', outputDir);
fprintf('============================================================\n\n');

%% ========================================================================
% 3. VIDEO METADATA AND SAMPLING PLAN
% =========================================================================
vidObj = VideoReader(videoPath);
originalFrameRate = vidObj.FrameRate;
videoDuration = vidObj.Duration;
estimatedTotalFrames = max(1, floor(videoDuration * originalFrameRate));

lastRequestedFrame = min(cfg.endFrame, estimatedTotalFrames);
firstRequestedFrame = max(1, round(cfg.startFrame));
if lastRequestedFrame < firstRequestedFrame
    error('cfg.endFrame must be greater than or equal to cfg.startFrame.');
end

availableFrames = lastRequestedFrame - firstRequestedFrame + 1;
frameInterval = max(floor(availableFrames / max(cfg.desiredSamples, 1)), 1);
dtSample = frameInterval / originalFrameRate;
sampleFrequency = 1 / dtSample;
estimatedSampledFrames = floor((availableFrames - 1) / frameInterval) + 1;
estimatedFlowSamples = max(estimatedSampledFrames - 1, 1);
gifStride = max(1, ceil(estimatedFlowSamples / max(cfg.maxGifFrames, 1)));

fprintf('Video duration             : %.3f s\n', videoDuration);
fprintf('Video frame rate           : %.3f fps\n', originalFrameRate);
fprintf('Estimated original frames  : %d\n', estimatedTotalFrames);
fprintf('Sampling every             : %d original frame(s)\n', frameInterval);
fprintf('Sample time step           : %.6f s\n', dtSample);
fprintf('Sample frequency           : %.3f Hz\n', sampleFrequency);

usePhysicalUnits = isfinite(cfg.metersPerPixel) && cfg.metersPerPixel > 0;
if usePhysicalUnits
    velocityScale = cfg.metersPerPixel / dtSample;
    spatialStep = cfg.metersPerPixel;
    velocityUnit = 'm/s';
    lengthUnit = 'm';
    vorticityUnit = '1/s';
else
    velocityScale = 1 / dtSample;
    spatialStep = 1;
    velocityUnit = 'pixel/s';
    lengthUnit = 'pixel';
    vorticityUnit = '1/s';
    warning(['No valid metres-per-pixel calibration was supplied. ', ...
             'Velocity outputs will be in pixel/s and dimensionless-number ', ...
             'analysis will be skipped.']);
end

%% ========================================================================
% 4. STREAMING VIDEO PROCESSING AND OPTICAL FLOW
% =========================================================================
opticFlow = opticalFlowFarneback;
numProbes = size(cfg.probePoints, 1);
probeLabels = arrayfun(@(p) sprintf('P%d', p), 1:numProbes, ...
    'UniformOutput', false);

% Preallocate probe data
uProbe = nan(estimatedFlowSamples, numProbes);
vProbe = nan(estimatedFlowSamples, numProbes);
speedProbe = nan(estimatedFlowSamples, numProbes);
timeSeconds = nan(estimatedFlowSamples, 1);
sourceFrameNumber = nan(estimatedFlowSamples, 1);

% These are initialized after the first sampled frame reveals image dimensions
sumU = [];
sumV = [];
sumU2 = [];
sumV2 = [];
sumUV = [];
sumOmega = [];
sumOmega2 = [];
sumPseudoDissipation = [];
firstGray = [];
firstRGB = [];
frameHeight = [];
frameWidth = [];
probePoints = cfg.probePoints;
plumeY = [];
plumeWidthPx = [];
plumeLeftPx = [];
plumeRightPx = [];
plumeCenterPx = [];

% Output animation paths
diagnosticGifPath = fullfile(gifDir, 'flow_vorticity_diagnostics.gif');
plumeGifPath = fullfile(gifDir, 'plume_width_evolution.gif');
diagnosticMp4Path = fullfile(gifDir, 'flow_vorticity_diagnostics.mp4');
if isfile(diagnosticGifPath), delete(diagnosticGifPath); end
if isfile(plumeGifPath), delete(plumeGifPath); end

if cfg.makeDiagnosticMP4
    diagnosticWriter = VideoWriter(diagnosticMp4Path, 'MPEG-4');
    diagnosticWriter.FrameRate = min(10, max(1, 1 / cfg.gifDelaySeconds));
    open(diagnosticWriter);
else
    diagnosticWriter = [];
end

originalFrameIndex = 0;
sampledFrameIndex = 0;
flowSampleIndex = 0;
firstSampleOriginalIndex = NaN;
flowFieldCount = 0;

while hasFrame(vidObj)
    rgbFrame = readFrame(vidObj);
    originalFrameIndex = originalFrameIndex + 1;

    if originalFrameIndex < firstRequestedFrame
        continue;
    end
    if originalFrameIndex > lastRequestedFrame
        break;
    end
    if mod(originalFrameIndex - firstRequestedFrame, frameInterval) ~= 0
        continue;
    end

    sampledFrameIndex = sampledFrameIndex + 1;
    grayFrame = toGray(rgbFrame);

    if sampledFrameIndex == 1
        firstSampleOriginalIndex = originalFrameIndex;
        firstGray = grayFrame;
        firstRGB = rgbFrame;
        [frameHeight, frameWidth] = size(grayFrame);

        % Clamp probe windows safely inside the image
        minX = 1 + cfg.probeHalfWindow;
        maxX = frameWidth - cfg.probeHalfWindow;
        minY = 1 + cfg.probeHalfWindow;
        maxY = frameHeight - cfg.probeHalfWindow;
        probePoints(:, 1) = min(max(round(probePoints(:, 1)), minX), maxX);
        probePoints(:, 2) = min(max(round(probePoints(:, 2)), minY), maxY);

        % Automatic plume rows if none are supplied
        if cfg.enablePlumeWidth
            if isempty(cfg.plumeYPositions)
                plumeY = unique(round(linspace( ...
                    max(2, round(0.20 * frameHeight)), ...
                    min(frameHeight - 1, round(0.88 * frameHeight)), 12)));
            else
                plumeY = unique(round(cfg.plumeYPositions(:)'));
                plumeY = plumeY(plumeY >= 1 & plumeY <= frameHeight);
            end
            if isempty(plumeY)
                warning('No valid plume Y positions remain; plume-width analysis disabled.');
                cfg.enablePlumeWidth = false;
            else
                nPlumeRows = numel(plumeY);
                plumeWidthPx = nan(estimatedFlowSamples, nPlumeRows);
                plumeLeftPx = nan(estimatedFlowSamples, nPlumeRows);
                plumeRightPx = nan(estimatedFlowSamples, nPlumeRows);
                plumeCenterPx = nan(estimatedFlowSamples, nPlumeRows);
            end
        end

        % Initialize cumulative flow-field statistics as single precision
        sumU = zeros(frameHeight, frameWidth, 'single');
        sumV = zeros(frameHeight, frameWidth, 'single');
        sumU2 = zeros(frameHeight, frameWidth, 'single');
        sumV2 = zeros(frameHeight, frameWidth, 'single');
        sumUV = zeros(frameHeight, frameWidth, 'single');
        sumOmega = zeros(frameHeight, frameWidth, 'single');
        sumOmega2 = zeros(frameHeight, frameWidth, 'single');
        if usePhysicalUnits
            sumPseudoDissipation = zeros(frameHeight, frameWidth, 'single');
        end

        % Initialize optical flow with the first sampled frame
        estimateFlow(opticFlow, grayFrame);

        % Save probe-location reference immediately
        f = figure('Visible', cfg.figureVisible, 'Color', 'w');
        imshow(firstGray); hold on;
        plot(probePoints(:, 1), probePoints(:, 2), 'ro', ...
            'MarkerSize', 8, 'LineWidth', 1.8);
        for p = 1:numProbes
            text(probePoints(p,1) + 5, probePoints(p,2), probeLabels{p}, ...
                'Color', 'yellow', 'FontWeight', 'bold', 'FontSize', 9);
        end
        title('Probe locations used for optical-flow sampling');
        hold off;
        saveFigureBoth(f, figDir, '01_probe_locations', cfg);
        close(f);
        continue;
    end

    % Estimate displacement between the previous and current sampled frame
    flow = estimateFlow(opticFlow, grayFrame);
    flowSampleIndex = flowSampleIndex + 1;

    % Apparent velocities in m/s (calibrated) or pixel/s (uncalibrated)
    uField = double(flow.Vx) * velocityScale;
    % Image y increases downward; use physical convention v > 0 upward
    vField = -double(flow.Vy) * velocityScale;
    speedField = hypot(uField, vField);

    % Spatial gradients and 2-D out-of-plane vorticity
    [dUdx, dUdyDown] = gradient(uField, spatialStep, spatialStep);
    [dVdx, dVdyDown] = gradient(vField, spatialStep, spatialStep);
    omegaZ = dVdx + dUdyDown;  % because y_physical = -y_image

    % 2-D pseudo-dissipation estimate, only meaningful with SI calibration
    if usePhysicalUnits
        dUdyUp = -dUdyDown;
        dVdyUp = -dVdyDown;
        Sxx = dUdx;
        Syy = dVdyUp;
        Sxy = 0.5 * (dUdyUp + dVdx);
        pseudoDissipation = 2 * cfg.kinematicViscosity .* ...
            (Sxx.^2 + Syy.^2 + 2 * Sxy.^2);
    else
        pseudoDissipation = [];
    end

    % Time and source-frame bookkeeping
    timeSeconds(flowSampleIndex) = ...
        (originalFrameIndex - firstSampleOriginalIndex) / originalFrameRate;
    sourceFrameNumber(flowSampleIndex) = originalFrameIndex;

    % Local window-averaged probe velocities
    for p = 1:numProbes
        x = probePoints(p, 1);
        y = probePoints(p, 2);
        xRange = (x - cfg.probeHalfWindow):(x + cfg.probeHalfWindow);
        yRange = (y - cfg.probeHalfWindow):(y + cfg.probeHalfWindow);
        uProbe(flowSampleIndex, p) = mean(uField(yRange, xRange), 'all', 'omitnan');
        vProbe(flowSampleIndex, p) = mean(vField(yRange, xRange), 'all', 'omitnan');
        speedProbe(flowSampleIndex, p) = hypot( ...
            uProbe(flowSampleIndex, p), vProbe(flowSampleIndex, p));
    end

    % Online full-field statistics
    sumU = sumU + single(uField);
    sumV = sumV + single(vField);
    sumU2 = sumU2 + single(uField.^2);
    sumV2 = sumV2 + single(vField.^2);
    sumUV = sumUV + single(uField .* vField);
    sumOmega = sumOmega + single(omegaZ);
    sumOmega2 = sumOmega2 + single(omegaZ.^2);
    if usePhysicalUnits
        sumPseudoDissipation = sumPseudoDissipation + single(pseudoDissipation);
    end
    flowFieldCount = flowFieldCount + 1;

    % Plume-width detection at selected horizontal rows
    if cfg.enablePlumeWidth
        [currentWidth, currentLeft, currentRight, currentCenter] = ...
            detectPlumeWidths(grayFrame, plumeY, cfg);
        plumeWidthPx(flowSampleIndex, :) = currentWidth;
        plumeLeftPx(flowSampleIndex, :) = currentLeft;
        plumeRightPx(flowSampleIndex, :) = currentRight;
        plumeCenterPx(flowSampleIndex, :) = currentCenter;
    else
        currentWidth = [];
        currentLeft = [];
        currentRight = [];
    end

    % Diagnostic GIF / MP4, rate-limited to cfg.maxGifFrames
    if mod(flowSampleIndex - 1, gifStride) == 0
        if cfg.makeDiagnosticGIF || cfg.makeDiagnosticMP4
            rgbDiagnostic = renderDiagnosticFrame( ...
                grayFrame, flow.Vx, flow.Vy, speedField, omegaZ, ...
                probePoints, timeSeconds(flowSampleIndex), ...
                velocityUnit, vorticityUnit, cfg);

            if cfg.makeDiagnosticGIF
                appendRGBToGif(rgbDiagnostic, diagnosticGifPath, ...
                    cfg.gifDelaySeconds, flowSampleIndex == 1);
            end
            if cfg.makeDiagnosticMP4
                writeVideo(diagnosticWriter, rgbDiagnostic);
            end
        end

        if cfg.makePlumeGIF && cfg.enablePlumeWidth
            rgbPlume = renderPlumeFrame(rgbFrame, plumeY, currentLeft, ...
                currentRight, currentWidth, cfg, ...
                timeSeconds(flowSampleIndex), usePhysicalUnits);
            appendRGBToGif(rgbPlume, plumeGifPath, ...
                cfg.gifDelaySeconds, flowSampleIndex == 1);
        end
    end

    if mod(flowSampleIndex, 50) == 0
        fprintf('Processed %d optical-flow samples...\n', flowSampleIndex);
    end
end

if cfg.makeDiagnosticMP4
    close(diagnosticWriter);
end

if flowSampleIndex < 4
    error('Too few sampled frames were processed. Use a longer video or reduce frameInterval.');
end

% Trim preallocated arrays to actual length
uProbe = uProbe(1:flowSampleIndex, :);
vProbe = vProbe(1:flowSampleIndex, :);
speedProbe = speedProbe(1:flowSampleIndex, :);
timeSeconds = timeSeconds(1:flowSampleIndex);
sourceFrameNumber = sourceFrameNumber(1:flowSampleIndex);
if cfg.enablePlumeWidth
    plumeWidthPx = plumeWidthPx(1:flowSampleIndex, :);
    plumeLeftPx = plumeLeftPx(1:flowSampleIndex, :);
    plumeRightPx = plumeRightPx(1:flowSampleIndex, :);
    plumeCenterPx = plumeCenterPx(1:flowSampleIndex, :);
end

fprintf('Actual optical-flow samples: %d\n', flowSampleIndex);

%% ========================================================================
% 5. FULL-FIELD MEAN, FLUCTUATION, TKE, VORTICITY AND DISSIPATION
% =========================================================================
meanUField = double(sumU) / flowFieldCount;
meanVField = double(sumV) / flowFieldCount;
meanSpeedField = hypot(meanUField, meanVField);
varUField = max(double(sumU2) / flowFieldCount - meanUField.^2, 0);
varVField = max(double(sumV2) / flowFieldCount - meanVField.^2, 0);
covUVField = double(sumUV) / flowFieldCount - meanUField .* meanVField;
tke2DField = 0.5 * (varUField + varVField);
meanOmegaField = double(sumOmega) / flowFieldCount;
rmsOmegaField = sqrt(max(double(sumOmega2) / flowFieldCount - meanOmegaField.^2, 0));
if usePhysicalUnits
    meanPseudoDissipationField = double(sumPseudoDissipation) / flowFieldCount;
else
    meanPseudoDissipationField = [];
end

%% ========================================================================
% 6. PROBE-BASED TURBULENCE STATISTICS
% =========================================================================
meanU = mean(uProbe, 1, 'omitnan');
meanV = mean(vProbe, 1, 'omitnan');
meanSpeedVector = hypot(meanU, meanV);
meanSpeedMagnitude = mean(speedProbe, 1, 'omitnan');

uFluct = uProbe - meanU;
vFluct = vProbe - meanV;

uu = mean(uFluct.^2, 1, 'omitnan');
vv = mean(vFluct.^2, 1, 'omitnan');
uv = mean(uFluct .* vFluct, 1, 'omitnan');
uRMS = sqrt(uu);
vRMS = sqrt(vv);
tke2D = 0.5 * (uu + vv);
turbulenceIntensity = 100 * sqrt(uu + vv) ./ max(meanSpeedVector, eps);

skewU = skewness(uProbe, 0, 1);
kurtU = kurtosis(uProbe, 0, 1);
skewV = skewness(vProbe, 0, 1);
kurtV = kurtosis(vProbe, 0, 1);

% Correlations and integral time scales
maxLagSamples = min(flowSampleIndex - 1, ...
    max(1, round(cfg.maxCorrelationLagSeconds * sampleFrequency)));
positiveLagTime = (0:maxLagSamples)' / sampleFrequency;
autoCorrU = nan(maxLagSamples + 1, numProbes);
autoCorrV = nan(maxLagSamples + 1, numProbes);
integralTimeU = nan(1, numProbes);
integralTimeV = nan(1, numProbes);

for p = 1:numProbes
    [acfUFull, lagU] = xcorr(uFluct(:,p), maxLagSamples, 'coeff');
    [acfVFull, lagV] = xcorr(vFluct(:,p), maxLagSamples, 'coeff');
    acfUPos = acfUFull(lagU >= 0);
    acfVPos = acfVFull(lagV >= 0);
    autoCorrU(:,p) = acfUPos(:);
    autoCorrV(:,p) = acfVPos(:);
    integralTimeU(p) = positiveAreaUntilFirstZero(positiveLagTime, acfUPos);
    integralTimeV(p) = positiveAreaUntilFirstZero(positiveLagTime, acfVPos);
end

% Existing requested two-point correlation: P1 vs P2 for u
[corrU12, lagsU12] = xcorr(uFluct(:,1), uFluct(:,min(2,numProbes)), 'coeff');
lagTimeU12 = lagsU12(:) / sampleFrequency;
zeroLagCorrU = corrcoef(uProbe, 'Rows', 'pairwise');
zeroLagCorrV = corrcoef(vProbe, 'Rows', 'pairwise');

% Power spectral density for every probe
if flowSampleIndex >= 16
    segmentLength = min(256, max(8, floor(flowSampleIndex / 4)));
    overlapLength = floor(0.5 * segmentLength);
    nfft = max(256, 2^nextpow2(segmentLength));
    [examplePSD, frequencyHz] = pwelch(uFluct(:,1), hamming(segmentLength), ...
        overlapLength, nfft, sampleFrequency);
    psdU = nan(numel(examplePSD), numProbes);
    psdV = nan(numel(examplePSD), numProbes);
    dominantFrequencyU = nan(1, numProbes);
    dominantFrequencyV = nan(1, numProbes);
    for p = 1:numProbes
        [psdU(:,p), ~] = pwelch(uFluct(:,p), hamming(segmentLength), ...
            overlapLength, nfft, sampleFrequency);
        [psdV(:,p), ~] = pwelch(vFluct(:,p), hamming(segmentLength), ...
            overlapLength, nfft, sampleFrequency);
        if numel(frequencyHz) > 1
            [~, idxU] = max(psdU(2:end,p));
            [~, idxV] = max(psdV(2:end,p));
            dominantFrequencyU(p) = frequencyHz(idxU + 1);
            dominantFrequencyV(p) = frequencyHz(idxV + 1);
        end
    end
else
    frequencyHz = [];
    psdU = [];
    psdV = [];
    dominantFrequencyU = nan(1, numProbes);
    dominantFrequencyV = nan(1, numProbes);
    warning('Fewer than 16 flow samples: PSD analysis was skipped.');
end

%% ========================================================================
% 7. PLUME SPREADING, FLUX AND ENTRAINMENT PROXY
% =========================================================================
plumeResults = struct();
if cfg.enablePlumeWidth
    meanPlumeWidthPx = mean(plumeWidthPx, 1, 'omitnan');
    stdPlumeWidthPx = std(plumeWidthPx, 0, 1, 'omitnan');
    meanPlumeLeftPx = mean(plumeLeftPx, 1, 'omitnan');
    meanPlumeRightPx = mean(plumeRightPx, 1, 'omitnan');

    if usePhysicalUnits
        meanPlumeWidth = meanPlumeWidthPx * cfg.metersPerPixel;
        stdPlumeWidth = stdPlumeWidthPx * cfg.metersPerPixel;
        widthTimeSeries = plumeWidthPx * cfg.metersPerPixel;
    else
        meanPlumeWidth = meanPlumeWidthPx;
        stdPlumeWidth = stdPlumeWidthPx;
        widthTimeSeries = plumeWidthPx;
    end

    % Height measured upward from the lowest selected row
    if usePhysicalUnits
        plumeHeight = (max(plumeY) - plumeY(:)) * cfg.metersPerPixel;
    else
        plumeHeight = max(plumeY) - plumeY(:);
    end
    [plumeHeightSorted, sortIdx] = sort(plumeHeight, 'ascend');
    meanWidthSorted = meanPlumeWidth(sortIdx)';
    stdWidthSorted = stdPlumeWidth(sortIdx)';

    validFit = isfinite(plumeHeightSorted) & isfinite(meanWidthSorted) & meanWidthSorted > 0;
    if nnz(validFit) >= 2
        widthFit = polyfit(plumeHeightSorted(validFit), meanWidthSorted(validFit), 1);
        spreadingRate = widthFit(1);
    else
        widthFit = [NaN NaN];
        spreadingRate = NaN;
    end

    % 2-D volume-flux and entrainment proxy from the mean upward velocity
    q2D = nan(numel(plumeY), 1);
    centerlineV = nan(numel(plumeY), 1);
    for i = 1:numel(plumeY)
        y = plumeY(i);
        left = max(1, round(meanPlumeLeftPx(i)));
        right = min(frameWidth, round(meanPlumeRightPx(i)));
        if isfinite(left) && isfinite(right) && right > left
            rowV = meanVField(y, left:right);
            rowVPositive = max(rowV, 0);
            xLocal = (0:(numel(rowVPositive)-1)) * spatialStep;
            q2D(i) = trapz(xLocal, rowVPositive);
            centerlineV(i) = max(rowVPositive);
        end
    end
    q2DSorted = q2D(sortIdx);
    centerlineVSorted = centerlineV(sortIdx);
    if nnz(isfinite(q2DSorted)) >= 3
        dQdZ = gradient(fillmissing(q2DSorted, 'linear', 'EndValues', 'nearest'), ...
            plumeHeightSorted);
        entrainmentAlphaProxy = dQdZ ./ (2 * max(centerlineVSorted, eps));
    else
        dQdZ = nan(size(q2DSorted));
        entrainmentAlphaProxy = nan(size(q2DSorted));
    end

    plumeResults.plumeY_pixels = plumeY(:);
    plumeResults.height = plumeHeightSorted;
    plumeResults.meanWidth = meanWidthSorted;
    plumeResults.stdWidth = stdWidthSorted;
    plumeResults.spreadingRate = spreadingRate;
    plumeResults.q2D = q2DSorted;
    plumeResults.dQdZ = dQdZ;
    plumeResults.centerlineV = centerlineVSorted;
    plumeResults.entrainmentAlphaProxy = entrainmentAlphaProxy;
else
    meanPlumeWidthPx = [];
    widthTimeSeries = [];
    spreadingRate = NaN;
end

%% ========================================================================
% 8. DIMENSIONLESS NUMBERS AND APPROXIMATE SMALL-SCALE METRICS
% =========================================================================
dimensionlessResults = struct();
if usePhysicalUnits
    localRe = meanSpeedVector * cfg.referenceLength_m / cfg.kinematicViscosity;
    reducedGravity = cfg.gravity * ...
        (cfg.rhoAmbient - cfg.rhoPlume) / cfg.rhoAmbient;
    if reducedGravity > 0
        localFr = meanSpeedVector ./ sqrt(reducedGravity * cfg.referenceLength_m);
        localRi = reducedGravity * cfg.referenceLength_m ./ max(meanSpeedVector.^2, eps);
    else
        localFr = nan(size(meanSpeedVector));
        localRi = nan(size(meanSpeedVector));
    end

    centerlineVelocity = max(abs(meanV));
    overallRe = centerlineVelocity * cfg.referenceLength_m / cfg.kinematicViscosity;
    if reducedGravity > 0
        overallFr = centerlineVelocity / sqrt(reducedGravity * cfg.referenceLength_m);
        overallRi = reducedGravity * cfg.referenceLength_m / max(centerlineVelocity^2, eps);
    else
        overallFr = NaN;
        overallRi = NaN;
    end

    % Approximate 2-D dissipation and Kolmogorov scales
    positiveDissipation = meanPseudoDissipationField( ...
        isfinite(meanPseudoDissipationField) & meanPseudoDissipationField > 0);
    if isempty(positiveDissipation)
        meanEpsilon2D = NaN;
        kolmogorovLength = NaN;
        kolmogorovTime = NaN;
    else
        meanEpsilon2D = mean(positiveDissipation, 'omitnan');
        kolmogorovLength = (cfg.kinematicViscosity^3 / meanEpsilon2D)^0.25;
        kolmogorovTime = sqrt(cfg.kinematicViscosity / meanEpsilon2D);
    end

    dimensionlessResults.localRe = localRe;
    dimensionlessResults.localFr = localFr;
    dimensionlessResults.localRi = localRi;
    dimensionlessResults.centerlineVelocity = centerlineVelocity;
    dimensionlessResults.overallRe = overallRe;
    dimensionlessResults.overallFr = overallFr;
    dimensionlessResults.overallRi = overallRi;
    dimensionlessResults.reducedGravity = reducedGravity;
    dimensionlessResults.meanEpsilon2D = meanEpsilon2D;
    dimensionlessResults.kolmogorovLength = kolmogorovLength;
    dimensionlessResults.kolmogorovTime = kolmogorovTime;
else
    localRe = nan(1, numProbes);
    localFr = nan(1, numProbes);
    localRi = nan(1, numProbes);
    overallRe = NaN;
    overallFr = NaN;
    overallRi = NaN;
    meanEpsilon2D = NaN;
    kolmogorovLength = NaN;
    kolmogorovTime = NaN;
end

%% ========================================================================
% 9. SAVE ALL RESULT FIGURES
% =========================================================================
probeNumber = 1:numProbes;
selectedProbe = min(max(round(cfg.psdProbe), 1), numProbes);

% 02 — Probe velocity time series
f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1200 750]);
subplot(2,1,1);
plot(timeSeconds, uProbe, 'LineWidth', 1.0);
xlabel('Time (s)'); ylabel(['u (' velocityUnit ')']);
title('Horizontal apparent velocity at all probes');
grid on; legend(probeLabels, 'Location', 'eastoutside');
subplot(2,1,2);
plot(timeSeconds, vProbe, 'LineWidth', 1.0);
xlabel('Time (s)'); ylabel(['v upward (' velocityUnit ')']);
title('Vertical apparent velocity at all probes');
grid on; legend(probeLabels, 'Location', 'eastoutside');
sgtitle('Probe-resolved velocity time histories');
saveFigureBoth(f, figDir, '02_probe_velocity_time_series', cfg); close(f);

% 03 — Mean velocity quantities
f = figure('Visible', cfg.figureVisible, 'Color', 'w');
plot(probeNumber, meanU, '-o', 'LineWidth', 1.5); hold on;
plot(probeNumber, meanV, '-s', 'LineWidth', 1.5);
plot(probeNumber, meanSpeedVector, '-d', 'LineWidth', 1.5);
plot(probeNumber, meanSpeedMagnitude, '-^', 'LineWidth', 1.5);
xlabel('Probe number'); ylabel(['Velocity (' velocityUnit ')']);
title('Mean velocity statistics across probes');
legend('<u>', '<v>', '|<U>|', '<|U|>', 'Location', 'best');
grid on; hold off;
saveFigureBoth(f, figDir, '03_mean_velocity_across_probes', cfg); close(f);

% 04 — RMS, TKE and turbulence intensity
f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1100 850]);
subplot(3,1,1);
plot(probeNumber, uRMS, '-o', probeNumber, vRMS, '-s', 'LineWidth', 1.5);
ylabel(['RMS (' velocityUnit ')']); legend('u_{rms}', 'v_{rms}', 'Location', 'best');
title('Velocity fluctuation RMS'); grid on;
subplot(3,1,2);
plot(probeNumber, tke2D, '-d', 'LineWidth', 1.5);
ylabel(['k_{2D} (' velocityUnit '^2)']); title('Two-dimensional TKE estimate'); grid on;
subplot(3,1,3);
plot(probeNumber, turbulenceIntensity, '-^', 'LineWidth', 1.5);
xlabel('Probe number'); ylabel('TI (%)'); title('Turbulence intensity'); grid on;
sgtitle('Turbulence intensity and kinetic-energy statistics');
saveFigureBoth(f, figDir, '04_rms_tke_turbulence_intensity', cfg); close(f);

% 05 — Reynolds stresses
f = figure('Visible', cfg.figureVisible, 'Color', 'w');
plot(probeNumber, uu, '-o', 'LineWidth', 1.5); hold on;
plot(probeNumber, vv, '-s', 'LineWidth', 1.5);
plot(probeNumber, uv, '-d', 'LineWidth', 1.5);
xlabel('Probe number'); ylabel(['Second moment (' velocityUnit '^2)']);
legend('<u''u''>', '<v''v''>', '<u''v''>', 'Location', 'best');
title('Reynolds-stress components at probe locations'); grid on; hold off;
saveFigureBoth(f, figDir, '05_reynolds_stresses', cfg); close(f);

% 06 — Skewness and flatness/kurtosis
f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1100 800]);
subplot(2,2,1); bar(probeNumber, skewU); title('Skewness of u'); xlabel('Probe'); grid on;
subplot(2,2,2); bar(probeNumber, kurtU); title('Kurtosis of u'); xlabel('Probe'); grid on;
subplot(2,2,3); bar(probeNumber, skewV); title('Skewness of v'); xlabel('Probe'); grid on;
subplot(2,2,4); bar(probeNumber, kurtV); title('Kurtosis of v'); xlabel('Probe'); grid on;
sgtitle('Higher-order velocity statistics');
saveFigureBoth(f, figDir, '06_skewness_kurtosis', cfg); close(f);

% 07 — Two-point correlation P1-P2
f = figure('Visible', cfg.figureVisible, 'Color', 'w');
plot(lagTimeU12, corrU12, 'LineWidth', 1.5);
xlabel('Time lag (s)'); ylabel('Correlation coefficient');
title(sprintf('Two-point u correlation: P1 versus P%d', min(2,numProbes)));
grid on; xlim([-cfg.maxCorrelationLagSeconds cfg.maxCorrelationLagSeconds]);
saveFigureBoth(f, figDir, '07_two_point_correlation_P1_P2', cfg); close(f);

% 08 — Zero-lag correlation matrices
f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1100 480]);
subplot(1,2,1); imagesc(zeroLagCorrU, [-1 1]); axis image; colorbar;
title('Zero-lag correlation matrix: u'); xlabel('Probe'); ylabel('Probe');
set(gca, 'XTick', probeNumber, 'YTick', probeNumber);
subplot(1,2,2); imagesc(zeroLagCorrV, [-1 1]); axis image; colorbar;
title('Zero-lag correlation matrix: v'); xlabel('Probe'); ylabel('Probe');
set(gca, 'XTick', probeNumber, 'YTick', probeNumber);
sgtitle('Spatial coherence between probe signals');
saveFigureBoth(f, figDir, '08_probe_correlation_matrices', cfg); close(f);

% 09 — Autocorrelation and integral time scales
f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1200 760]);
subplot(2,1,1);
plot(positiveLagTime, autoCorrU, 'LineWidth', 1.0);
xlabel('Lag (s)'); ylabel('R_{uu}'); title('u autocorrelation'); grid on;
legend(probeLabels, 'Location', 'eastoutside');
subplot(2,1,2);
plot(probeNumber, integralTimeU, '-o', 'LineWidth', 1.5); hold on;
plot(probeNumber, integralTimeV, '-s', 'LineWidth', 1.5);
xlabel('Probe number'); ylabel('Integral time scale (s)');
legend('T_u', 'T_v', 'Location', 'best'); title('Integral time scales'); grid on;
sgtitle('Temporal correlation analysis');
saveFigureBoth(f, figDir, '09_autocorrelation_integral_times', cfg); close(f);

% 10 — PSD and dominant frequencies
if ~isempty(frequencyHz)
    f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1100 800]);
    subplot(2,1,1);
    loglog(frequencyHz(2:end), psdU(2:end,selectedProbe), 'LineWidth', 1.4); hold on;
    loglog(frequencyHz(2:end), psdV(2:end,selectedProbe), 'LineWidth', 1.4);
    xlabel('Frequency (Hz)'); ylabel('PSD');
    title(sprintf('Velocity spectra at P%d', selectedProbe));
    legend('u PSD', 'v PSD', 'Location', 'best'); grid on;
    subplot(2,1,2);
    plot(probeNumber, dominantFrequencyU, '-o', 'LineWidth', 1.5); hold on;
    plot(probeNumber, dominantFrequencyV, '-s', 'LineWidth', 1.5);
    xlabel('Probe number'); ylabel('Dominant frequency (Hz)');
    legend('u', 'v', 'Location', 'best'); title('Dominant spectral frequency'); grid on;
    sgtitle('Power spectral density analysis');
    saveFigureBoth(f, figDir, '10_power_spectral_density', cfg); close(f);
end

% 11 — Velocity PDFs at selected probe
f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1100 460]);
subplot(1,2,1);
histogram(uFluct(:,selectedProbe), cfg.pdfBins, 'Normalization', 'pdf');
xlabel(['u'' (' velocityUnit ')']); ylabel('PDF');
title(sprintf('u fluctuation PDF at P%d', selectedProbe)); grid on;
subplot(1,2,2);
histogram(vFluct(:,selectedProbe), cfg.pdfBins, 'Normalization', 'pdf');
xlabel(['v'' (' velocityUnit ')']); ylabel('PDF');
title(sprintf('v fluctuation PDF at P%d', selectedProbe)); grid on;
sgtitle('Velocity-fluctuation probability distributions');
saveFigureBoth(f, figDir, '11_velocity_fluctuation_PDF', cfg); close(f);

% 12 — Mean flow, mean speed, TKE and mean vorticity fields
f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [20 20 1400 900]);
subplot(2,2,1);
imagesc(meanSpeedField); axis image ij; colorbar;
title(['Mean speed (' velocityUnit ')']); xlabel('x pixel'); ylabel('y pixel');
subplot(2,2,2);
step = max(1, cfg.quiverStepPixels);
[Xq, Yq] = meshgrid(1:step:frameWidth, 1:step:frameHeight);
quiver(Xq, Yq, meanUField(1:step:end,1:step:end), ...
    -meanVField(1:step:end,1:step:end), 1.5);
axis image ij; xlim([1 frameWidth]); ylim([1 frameHeight]);
title('Mean velocity vectors'); xlabel('x pixel'); ylabel('y pixel');
subplot(2,2,3);
imagesc(tke2DField); axis image ij; colorbar;
title(['2-D TKE field (' velocityUnit '^2)']); xlabel('x pixel'); ylabel('y pixel');
subplot(2,2,4);
imagesc(meanOmegaField); axis image ij; colorbar;
title(['Mean vorticity (' vorticityUnit ')']); xlabel('x pixel'); ylabel('y pixel');
sgtitle('Full-field time-averaged optical-flow diagnostics');
saveFigureBoth(f, figDir, '12_mean_flow_tke_vorticity_fields', cfg); close(f);

% 13 — Vorticity RMS and pseudo-dissipation
f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1200 500]);
if usePhysicalUnits
    subplot(1,2,1);
    imagesc(rmsOmegaField); axis image ij; colorbar;
    title('Vorticity RMS (1/s)'); xlabel('x pixel'); ylabel('y pixel');
    subplot(1,2,2);
    imagesc(meanPseudoDissipationField); axis image ij; colorbar;
    title('Mean 2-D pseudo-dissipation (m^2/s^3)'); xlabel('x pixel'); ylabel('y pixel');
else
    imagesc(rmsOmegaField); axis image ij; colorbar;
    title('Vorticity RMS (1/s)'); xlabel('x pixel'); ylabel('y pixel');
end
sgtitle('Small-scale and rotational-flow indicators');
saveFigureBoth(f, figDir, '13_vorticity_rms_pseudo_dissipation', cfg); close(f);

% 14 — Plume width evolution and spreading
if cfg.enablePlumeWidth
    middleWidthIndex = round(numel(plumeY) / 2);
    f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1150 800]);
    subplot(2,1,1);
    plot(timeSeconds, widthTimeSeries(:,middleWidthIndex), 'LineWidth', 1.2);
    xlabel('Time (s)'); ylabel(['Width (' lengthUnit ')']);
    title(sprintf('Plume-width evolution at image row y = %d px', ...
        plumeY(middleWidthIndex))); grid on;
    subplot(2,1,2);
    errorbar(plumeResults.height, plumeResults.meanWidth, plumeResults.stdWidth, ...
        'o-', 'LineWidth', 1.2);
    xlabel(['Height above lowest row (' lengthUnit ')']);
    ylabel(['Mean plume width (' lengthUnit ')']);
    title(sprintf('Mean plume spreading; fitted dw/dz = %.4g', spreadingRate)); grid on;
    sgtitle('Image-based plume-width analysis');
    saveFigureBoth(f, figDir, '14_plume_width_and_spreading', cfg); close(f);

    % 15 — 2-D flux and entrainment proxy
    f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1150 800]);
    subplot(3,1,1);
    plot(plumeResults.q2D, plumeResults.height, '-o', 'LineWidth', 1.2);
    xlabel('2-D upward volume-flux proxy'); ylabel(['Height (' lengthUnit ')']);
    title('Integrated positive vertical optical-flow flux'); grid on;
    subplot(3,1,2);
    plot(plumeResults.dQdZ, plumeResults.height, '-s', 'LineWidth', 1.2);
    xlabel('dQ_{2D}/dz'); ylabel(['Height (' lengthUnit ')']);
    title('Flux-growth / entrainment-rate proxy'); grid on;
    subplot(3,1,3);
    plot(plumeResults.entrainmentAlphaProxy, plumeResults.height, '-d', 'LineWidth', 1.2);
    xlabel('\alpha proxy'); ylabel(['Height (' lengthUnit ')']);
    title('2-D entrainment-coefficient proxy'); grid on;
    sgtitle('Optical-flow-based entrainment diagnostics (interpret cautiously)');
    saveFigureBoth(f, figDir, '15_plume_flux_entrainment_proxy', cfg); close(f);
end

% 16 — Dimensionless quantities
if usePhysicalUnits
    f = figure('Visible', cfg.figureVisible, 'Color', 'w', 'Position', [50 50 1100 800]);
    subplot(3,1,1); plot(probeNumber, localRe, '-o', 'LineWidth', 1.5);
    ylabel('Re'); title('Local Reynolds number'); grid on;
    subplot(3,1,2); plot(probeNumber, localFr, '-s', 'LineWidth', 1.5);
    ylabel('Fr'); title('Densimetric Froude number'); grid on;
    subplot(3,1,3); plot(probeNumber, localRi, '-d', 'LineWidth', 1.5);
    xlabel('Probe number'); ylabel('Ri'); title('Richardson number'); grid on;
    sgtitle('Dimensionless flow indicators using configured physical parameters');
    saveFigureBoth(f, figDir, '16_dimensionless_numbers', cfg); close(f);
end

%% ========================================================================
% 10. SAVE NUMERICAL OUTPUTS TO CSV
% =========================================================================
% Probe time histories
velocityTable = table(timeSeconds, sourceFrameNumber, ...
    'VariableNames', {'Time_s', 'OriginalFrame'});
for p = 1:numProbes
    velocityTable.(sprintf('U_P%d', p)) = uProbe(:,p);
    velocityTable.(sprintf('V_P%d', p)) = vProbe(:,p);
    velocityTable.(sprintf('Speed_P%d', p)) = speedProbe(:,p);
end
writetable(velocityTable, fullfile(dataDir, 'probe_velocity_timeseries.csv'));

% Probe statistics
statisticsTable = table(probeNumber', probePoints(:,1), probePoints(:,2), ...
    meanU', meanV', meanSpeedVector', meanSpeedMagnitude', uRMS', vRMS', ...
    uu', vv', uv', tke2D', turbulenceIntensity', skewU', kurtU', ...
    skewV', kurtV', integralTimeU', integralTimeV', ...
    dominantFrequencyU', dominantFrequencyV', ...
    'VariableNames', {'Probe','X_pixel','Y_pixel','MeanU','MeanV', ...
    'MagnitudeOfMeanVelocity','MeanSpeedMagnitude','Urms','Vrms', ...
    'uu','vv','uv','TKE2D','TurbulenceIntensity_percent', ...
    'SkewnessU','KurtosisU','SkewnessV','KurtosisV', ...
    'IntegralTimeU_s','IntegralTimeV_s', ...
    'DominantFrequencyU_Hz','DominantFrequencyV_Hz'});
writetable(statisticsTable, fullfile(dataDir, 'probe_statistics.csv'));

% Two-point correlation
corrTable = table(lagTimeU12, corrU12(:), ...
    'VariableNames', {'Lag_s', 'Correlation_U_P1_P2'});
writetable(corrTable, fullfile(dataDir, 'two_point_correlation_P1_P2.csv'));

% Correlation matrices
writeLabeledMatrix(zeroLagCorrU, probeLabels, ...
    fullfile(dataDir, 'zero_lag_correlation_matrix_u.csv'));
writeLabeledMatrix(zeroLagCorrV, probeLabels, ...
    fullfile(dataDir, 'zero_lag_correlation_matrix_v.csv'));

% Autocorrelation
acfUTable = table(positiveLagTime, 'VariableNames', {'Lag_s'});
acfVTable = table(positiveLagTime, 'VariableNames', {'Lag_s'});
for p = 1:numProbes
    acfUTable.(sprintf('ACF_U_P%d', p)) = autoCorrU(:,p);
    acfVTable.(sprintf('ACF_V_P%d', p)) = autoCorrV(:,p);
end
writetable(acfUTable, fullfile(dataDir, 'autocorrelation_u.csv'));
writetable(acfVTable, fullfile(dataDir, 'autocorrelation_v.csv'));

% PSD
if ~isempty(frequencyHz)
    psdUTable = table(frequencyHz, 'VariableNames', {'Frequency_Hz'});
    psdVTable = table(frequencyHz, 'VariableNames', {'Frequency_Hz'});
    for p = 1:numProbes
        psdUTable.(sprintf('PSD_U_P%d', p)) = psdU(:,p);
        psdVTable.(sprintf('PSD_V_P%d', p)) = psdV(:,p);
    end
    writetable(psdUTable, fullfile(dataDir, 'power_spectral_density_u.csv'));
    writetable(psdVTable, fullfile(dataDir, 'power_spectral_density_v.csv'));
end

% Plume-width and entrainment outputs
if cfg.enablePlumeWidth
    plumeWidthTable = table(timeSeconds, 'VariableNames', {'Time_s'});
    for i = 1:numel(plumeY)
        plumeWidthTable.(sprintf('Width_y%d', plumeY(i))) = widthTimeSeries(:,i);
    end
    writetable(plumeWidthTable, fullfile(dataDir, 'plume_width_timeseries.csv'));

    plumeProfileTable = table(plumeResults.height, plumeResults.meanWidth, ...
        plumeResults.stdWidth, plumeResults.q2D, plumeResults.dQdZ, ...
        plumeResults.centerlineV, plumeResults.entrainmentAlphaProxy, ...
        'VariableNames', {'Height','MeanWidth','StdWidth','Q2D', ...
        'dQdZ','CenterlineV','EntrainmentAlphaProxy'});
    writetable(plumeProfileTable, fullfile(dataDir, 'plume_profile_and_entrainment.csv'));
end

% Dimensionless numbers
if usePhysicalUnits
    dimensionlessTable = table(probeNumber', localRe', localFr', localRi', ...
        'VariableNames', {'Probe','Re','Fr','Ri'});
    writetable(dimensionlessTable, fullfile(dataDir, 'dimensionless_numbers_by_probe.csv'));

    overallTable = table(cfg.referenceLength_m, cfg.kinematicViscosity, ...
        cfg.rhoAmbient, cfg.rhoPlume, dimensionlessResults.centerlineVelocity, ...
        overallRe, overallFr, overallRi, meanEpsilon2D, ...
        kolmogorovLength, kolmogorovTime, spreadingRate, ...
        'VariableNames', {'ReferenceLength_m','KinematicViscosity_m2s', ...
        'AmbientDensity_kgm3','PlumeDensity_kgm3','CenterlineVelocity_ms', ...
        'OverallRe','OverallFr','OverallRi','MeanPseudoDissipation_m2s3', ...
        'ApproxKolmogorovLength_m','ApproxKolmogorovTime_s','PlumeSpreadingRate'});
    writetable(overallTable, fullfile(dataDir, 'overall_physical_metrics.csv'));
end

%% ========================================================================
% 11. SAVE COMPLETE MATLAB RESULTS AND TEXT SUMMARY
% =========================================================================
results = struct();
results.cfg = cfg;
results.videoPath = videoPath;
results.outputDir = outputDir;
results.originalFrameRate = originalFrameRate;
results.frameInterval = frameInterval;
results.dtSample = dtSample;
results.sampleFrequency = sampleFrequency;
results.velocityUnit = velocityUnit;
results.lengthUnit = lengthUnit;
results.probePoints = probePoints;
results.timeSeconds = timeSeconds;
results.sourceFrameNumber = sourceFrameNumber;
results.uProbe = uProbe;
results.vProbe = vProbe;
results.speedProbe = speedProbe;
results.statisticsTable = statisticsTable;
results.meanUField = single(meanUField);
results.meanVField = single(meanVField);
results.meanSpeedField = single(meanSpeedField);
results.varUField = single(varUField);
results.varVField = single(varVField);
results.covUVField = single(covUVField);
results.tke2DField = single(tke2DField);
results.meanOmegaField = single(meanOmegaField);
results.rmsOmegaField = single(rmsOmegaField);
results.meanPseudoDissipationField = single(meanPseudoDissipationField);
results.autoCorrU = autoCorrU;
results.autoCorrV = autoCorrV;
results.positiveLagTime = positiveLagTime;
results.zeroLagCorrU = zeroLagCorrU;
results.zeroLagCorrV = zeroLagCorrV;
results.frequencyHz = frequencyHz;
results.psdU = psdU;
results.psdV = psdV;
results.plume = plumeResults;
results.dimensionless = dimensionlessResults;

save(fullfile(dataDir, 'New2_complete_results.mat'), 'results', '-v7.3');

summaryPath = fullfile(outputDir, 'RUN_SUMMARY.txt');
fid = fopen(summaryPath, 'w');
if fid < 0
    warning('Could not create RUN_SUMMARY.txt');
else
    fprintf(fid, 'NEW2 COMPLETE INCENSE-STICK TURBULENCE ANALYSIS\n');
    fprintf(fid, 'Generated: %s\n\n', datestr(now));
    fprintf(fid, 'Input video: %s\n', videoPath);
    fprintf(fid, 'Original FPS: %.6f\n', originalFrameRate);
    fprintf(fid, 'Frame interval: %d\n', frameInterval);
    fprintf(fid, 'Sample dt: %.8f s\n', dtSample);
    fprintf(fid, 'Optical-flow samples: %d\n', flowSampleIndex);
    fprintf(fid, 'Velocity unit: %s\n', velocityUnit);
    fprintf(fid, 'Length unit: %s\n', lengthUnit);
    fprintf(fid, 'Metres per pixel: %.8g\n', cfg.metersPerPixel);
    fprintf(fid, 'Probe half-window: %d px\n\n', cfg.probeHalfWindow);
    fprintf(fid, 'KEY OVERALL METRICS\n');
    fprintf(fid, 'Maximum |mean vertical velocity|: %.8g %s\n', max(abs(meanV)), velocityUnit);
    fprintf(fid, 'Maximum probe TKE2D: %.8g %s^2\n', max(tke2D), velocityUnit);
    fprintf(fid, 'Maximum probe turbulence intensity: %.8g %%\n', max(turbulenceIntensity));
    fprintf(fid, 'Plume spreading rate dw/dz: %.8g\n', spreadingRate);
    if usePhysicalUnits
        fprintf(fid, 'Overall Re: %.8g\n', overallRe);
        fprintf(fid, 'Overall Fr: %.8g\n', overallFr);
        fprintf(fid, 'Overall Ri: %.8g\n', overallRi);
        fprintf(fid, 'Approx. mean 2-D pseudo-dissipation: %.8g m^2/s^3\n', meanEpsilon2D);
        fprintf(fid, 'Approx. Kolmogorov length: %.8g m\n', kolmogorovLength);
        fprintf(fid, 'Approx. Kolmogorov time: %.8g s\n', kolmogorovTime);
    end
    fprintf(fid, '\nINTERPRETATION LIMITATIONS\n');
    fprintf(fid, ['1. Optical flow tracks image-pattern displacement, not automatically ', ...
        'the true gas velocity.\n']);
    fprintf(fid, ['2. Physical velocity and dimensionless numbers depend directly on ', ...
        'the accuracy of metresPerPixel and video timing.\n']);
    fprintf(fid, ['3. TKE2D excludes the out-of-plane velocity fluctuation and therefore ', ...
        'is not the complete three-dimensional turbulent kinetic energy.\n']);
    fprintf(fid, ['4. Vorticity, dissipation, Kolmogorov scales, plume width and ', ...
        'entrainment are optical-flow/image-based estimates and require ', ...
        'experimental validation.\n']);
    fclose(fid);
end

fprintf('\n============================================================\n');
fprintf('ANALYSIS COMPLETE\n');
fprintf('Figures : %s\n', figDir);
fprintf('GIFs    : %s\n', gifDir);
fprintf('Data    : %s\n', dataDir);
fprintf('Summary : %s\n', summaryPath);
fprintf('============================================================\n');

%% ========================================================================
% LOCAL HELPER FUNCTIONS
% =========================================================================
function gray = toGray(frame)
    if ndims(frame) == 2
        gray = frame;
    elseif size(frame,3) == 1
        gray = frame(:,:,1);
    else
        gray = rgb2gray(frame);
    end
end

function mkdirIfNeeded(folderPath)
    if ~exist(folderPath, 'dir')
        mkdir(folderPath);
    end
end

function saveFigureBoth(figHandle, figDir, baseName, cfg)
    pngPath = fullfile(figDir, [baseName '.png']);
    if exist('exportgraphics', 'file') == 2
        exportgraphics(figHandle, pngPath, 'Resolution', cfg.saveResolutionDPI);
    else
        print(figHandle, pngPath, '-dpng', sprintf('-r%d', cfg.saveResolutionDPI));
    end
    if cfg.saveMATLABFigures
        savefig(figHandle, fullfile(figDir, [baseName '.fig']));
    end
end

function [widths, leftEdges, rightEdges, centers] = ...
        detectPlumeWidths(grayFrame, yPositions, cfg)
    nRows = numel(yPositions);
    widths = nan(1, nRows);
    leftEdges = nan(1, nRows);
    rightEdges = nan(1, nRows);
    centers = nan(1, nRows);

    for i = 1:nRows
        y = yPositions(i);
        profile = double(grayFrame(y, :));
        if cfg.profileSmoothingPixels > 1
            profile = movmean(profile, cfg.profileSmoothingPixels);
        end
        med = median(profile, 'omitnan');
        robustSigma = 1.4826 * median(abs(profile - med), 'omitnan');
        if robustSigma <= eps
            robustSigma = std(profile, 0, 'omitnan');
        end
        if robustSigma <= eps
            continue;
        end

        polarity = lower(cfg.plumePolarity);
        if strcmp(polarity, 'auto')
            brightContrast = max(profile) - med;
            darkContrast = med - min(profile);
            if brightContrast >= darkContrast
                polarity = 'bright';
            else
                polarity = 'dark';
            end
        end

        if strcmp(polarity, 'dark')
            mask = profile < med - cfg.plumeThresholdSigma * robustSigma;
        else
            mask = profile > med + cfg.plumeThresholdSigma * robustSigma;
        end

        [left, right] = largestTrueRun(mask, cfg.minimumPlumeRunPixels);
        if isfinite(left) && isfinite(right)
            leftEdges(i) = left;
            rightEdges(i) = right;
            widths(i) = right - left + 1;
            centers(i) = 0.5 * (left + right);
        end
    end
end

function [bestLeft, bestRight] = largestTrueRun(mask, minRunLength)
    mask = logical(mask(:)');
    transitions = diff([false, mask, false]);
    runStarts = find(transitions == 1);
    runEnds = find(transitions == -1) - 1;
    if isempty(runStarts)
        bestLeft = NaN;
        bestRight = NaN;
        return;
    end
    runLengths = runEnds - runStarts + 1;
    valid = runLengths >= minRunLength;
    if ~any(valid)
        bestLeft = NaN;
        bestRight = NaN;
        return;
    end
    validStarts = runStarts(valid);
    validEnds = runEnds(valid);
    validLengths = runLengths(valid);
    [~, idx] = max(validLengths);
    bestLeft = validStarts(idx);
    bestRight = validEnds(idx);
end

function area = positiveAreaUntilFirstZero(timeVector, correlation)
    correlation = correlation(:);
    timeVector = timeVector(:);
    firstNonPositive = find(correlation(2:end) <= 0, 1, 'first');
    if isempty(firstNonPositive)
        lastIndex = numel(correlation);
    else
        lastIndex = firstNonPositive;
    end
    lastIndex = max(lastIndex, 2);
    area = trapz(timeVector(1:lastIndex), correlation(1:lastIndex));
end

function rgbImage = renderDiagnosticFrame(grayFrame, rawU, rawV, ...
        speedField, omegaZ, probePoints, timeValue, velocityUnit, ...
        vorticityUnit, cfg)
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [20 20 1500 500]);
    subplot(1,3,1);
    imshow(grayFrame); hold on;
    step = max(1, cfg.quiverStepPixels);
    [Xq, Yq] = meshgrid(1:step:size(grayFrame,2), 1:step:size(grayFrame,1));
    quiver(Xq, Yq, rawU(1:step:end,1:step:end), ...
        rawV(1:step:end,1:step:end), 1.5, 'y');
    plot(probePoints(:,1), probePoints(:,2), 'ro', 'MarkerSize', 5, 'LineWidth', 1);
    title(sprintf('Optical-flow vectors, t = %.3f s', timeValue)); hold off;

    subplot(1,3,2);
    imagesc(speedField); axis image ij; colorbar;
    title(['Speed (' velocityUnit ')']); xlabel('x pixel'); ylabel('y pixel');

    subplot(1,3,3);
    imagesc(omegaZ); axis image ij; colorbar;
    title(['Vorticity (' vorticityUnit ')']); xlabel('x pixel'); ylabel('y pixel');
    sgtitle('Incense-stick plume: optical-flow diagnostics');

    rgbImage = captureFigureRGB(f);
    close(f);
end

function rgbImage = renderPlumeFrame(rgbFrame, yPositions, leftEdges, ...
        rightEdges, widths, cfg, timeValue, usePhysicalUnits)
    f = figure('Visible', 'off', 'Color', 'w', 'Position', [20 20 900 650]);
    imshow(rgbFrame); hold on;
    for i = 1:numel(yPositions)
        if isfinite(leftEdges(i)) && isfinite(rightEdges(i))
            plot([leftEdges(i), rightEdges(i)], ...
                [yPositions(i), yPositions(i)], 'r-', 'LineWidth', 1.5);
            plot([leftEdges(i), rightEdges(i)], ...
                [yPositions(i), yPositions(i)], 'yo', 'MarkerSize', 3);
            if usePhysicalUnits
                labelValue = widths(i) * cfg.metersPerPixel * 1000;
                labelText = sprintf('%.2f mm', labelValue);
            else
                labelText = sprintf('%.1f px', widths(i));
            end
            text(rightEdges(i) + 4, yPositions(i), labelText, ...
                'Color', 'green', 'FontWeight', 'bold', 'FontSize', 8);
        end
    end
    title(sprintf('Detected plume widths, t = %.3f s', timeValue));
    hold off;
    rgbImage = captureFigureRGB(f);
    close(f);
end

function rgbImage = captureFigureRGB(figHandle)
    tempPng = [tempname '.png'];
    if exist('exportgraphics', 'file') == 2
        exportgraphics(figHandle, tempPng, 'Resolution', 110);
        rgbImage = imread(tempPng);
        delete(tempPng);
    else
        drawnow;
        frame = getframe(figHandle);
        rgbImage = frame2im(frame);
    end
    if size(rgbImage,3) == 4
        rgbImage = rgbImage(:,:,1:3);
    end
end

function appendRGBToGif(rgbImage, gifPath, delaySeconds, isFirstFrame)
    [indexedImage, colorMap] = rgb2ind(rgbImage, 256);
    if isFirstFrame || ~isfile(gifPath)
        imwrite(indexedImage, colorMap, gifPath, 'gif', ...
            'LoopCount', inf, 'DelayTime', delaySeconds);
    else
        imwrite(indexedImage, colorMap, gifPath, 'gif', ...
            'WriteMode', 'append', 'DelayTime', delaySeconds);
    end
end

function writeLabeledMatrix(matrixData, labels, outputPath)
    matrixTable = array2table(matrixData, 'VariableNames', labels);
    matrixTable = addvars(matrixTable, labels(:), 'Before', 1, ...
        'NewVariableNames', 'Probe');
    writetable(matrixTable, outputPath);
end
