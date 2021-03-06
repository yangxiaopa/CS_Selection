function [ IMs ] = optimize_ground_motions_par( selectionParams, targetSa, IMs )
% Parallelized greedy optimization, for variable definitions, see
% optimize_ground_motions(selectionParams, targetSa, IMs)

sampleSmall = IMs.sampleSmall;

display('Please wait...This algorithm takes a few minutes depending on the number of records to be selected');
if selectionParams.cond == 0
    display('The algorithm is slower when scaling is used');
end
if selectionParams.optType == 1
    display('The algorithm is slower when optimizing with the KS-test Dn statistic');
end

% if optimizing the ground motions by calculating the Dn value, first
% calculate the emperical CDF values (which will be the same at each
% period) and initialize a vector of Dn values
emp_cdf = 0;
if selectionParams.optType == 1
    emp_cdf = linspace(0,1,selectionParams.nGM+1);
end

numWorkers = 2;
parobj = parpool(numWorkers);

% Initialize scale factor vector
scaleFac = ones(selectionParams.nBig,1);
for k=1:selectionParams.nLoop % Number of passes
    
    for i=1:selectionParams.nGM % Selects nGM ground motions
        display([num2str(round(((k-1)*selectionParams.nGM + i-1)/(selectionParams.nLoop*selectionParams.nGM)*100)) '% done']);
        
        devTotal = zeros(selectionParams.nBig,1);
        sampleSmall(i,:) = [];
        IMs.recID(i,:) = [];
        
        if selectionParams.isScaled == 1
            if selectionParams.cond == 1
                scaleFac = exp(selectionParams.lnSa1)./exp(IMs.sampleBig(:,selectionParams.rec));
            elseif selectionParams.cond == 0
                [scaleFac, devTotal] = bestScaleFactorPar(IMs.sampleBig, sampleSmall, targetSa.meanReq, targetSa.stdevs, selectionParams.weights, selectionParams.maxScale);
            end
        end
        
        % Try to add a new spectra to the subset list
        % new function 
        [devTotal] = ParLoop(devTotal, scaleFac, selectionParams, sampleSmall, IMs.sampleBig, targetSa.meanReq,...
                             targetSa.stdevs, emp_cdf);                                
                                
        [minDevFinal, minID] = min(devTotal);
        % Add new element in the right slot
        if selectionParams.isScaled == 1
            IMs.scaleFac(i) = scaleFac(minID);
        else
            IMs.scaleFac(i) = 1;
        end
        sampleSmall = [sampleSmall(1:i-1,:);IMs.sampleBig(minID,:)+log(scaleFac(minID));sampleSmall(i:end,:)];
        IMs.recID = [IMs.recID(1:i-1);minID;IMs.recID(i:end)];
        
    end
    
    % Can the optimization be stopped after this loop based on the user
    % specified tolerance? Recalculate new standard deviations of new
    % sampleSmall and then recalculate new maximum percent errors of means
    % and standard deviations 
    if selectionParams.optType == 0
        notTcond = find(selectionParams.PerTgt ~= selectionParams.PerTgt(selectionParams.rec));
        stdevs = std(sampleSmall);
        meanErr = max(abs(exp(mean(sampleSmall))-targetSa.means)./targetSa.means)*100;
        stdErr = max(abs(stdevs(notTcond) - targetSa.stdevs(notTcond))./targetSa.stdevs(notTcond))*100;
        fprintf('Max (across periods) error in median = %3.1f percent \n', meanErr); 
        fprintf('Max (across periods) error in standard deviation = %3.1f percent \n \n', stdErr);
        
        % If error is now within the tolerance, break out of the
        % optimization
        if meanErr < selectionParams.tol && stdErr < selectionParams.tol
            display('The percent errors between chosen and target spectra are now within the required tolerances.');
            break;
        end
    end
    
    fprintf('End of loop %1.0f of %1.0f \n', k, selectionParams.nLoop) 
end

display('100% done');

% Save final selection for output
IMs.sampleSmall = sampleSmall;


delete(parobj);
end

function [scaleFac, minDev] = bestScaleFactorPar(sampleBig,sampleSmall,meanReq,sigma,weights,maxScale)
% Identifies the best scaled ground motions to be used with the greedy
% algortihm

% Determine size of sampleSmall for standard deviation calculations
scales = 0.1:0.1:maxScale;
scaleFac = zeros(size(sampleBig,1),1);
[nGM,~] = size(sampleSmall);
newGM = nGM+1;
minDev = zeros(length(scales),1);

parfor i = 1:size(sampleBig,1)
    devTotal = zeros(length(scales),1);
    
    for j=1:length(scales)
        
        sampleSmallNew = [sampleSmall;sampleBig(i,:)+log(scales(j))];
        
        % Compute deviations from target
        avg = sum(sampleSmallNew)./newGM;
        devMean = avg - meanReq;
        devSig = sqrt((1/(nGM))*sum((sampleSmallNew-repmat(avg,newGM,1)).^2))-sigma;
        devTotal(j) = weights(1) * sum(devMean.^2) + weights(2) * sum(devSig.^2);
        
    end
    
    [minDev(i), minID] = min(devTotal);
    
    if minDev(i) == 100000;
        scaleFac(i) = -99;
    else
        scaleFac(i) = scales(minID);
    end
    
    
end
end



function [ devTotal ] = ParLoop( devTotal, scaleFac, selectionParams, sampleSmall, sampleBig, meanReq, stdevs, emp_cdf )
% Parallel loop to use within greedy optimization
optType = selectionParams.optType;
if all(devTotal) && optType == 0 
    return;
end

PerTgt = selectionParams.PerTgt;
cond = selectionParams.cond;
isScaled = selectionParams.isScaled;
weights = selectionParams.weights;
penalty = selectionParams.penalty;
maxScale = selectionParams.maxScale;
recID = IMs.recID;



parfor j = 1:selectionParams.nBig
    sampleSmallTemp = [sampleSmall;sampleBig(j,:)+log(scaleFac(j))];
    
    % Calculate the appropriate measure of deviation and store in
    % devTotal (the D-statistic or the combination of mean and
    % sigma deviations)
    if optType == 0
        if cond == 1 || (cond == 0 && isScaled == 0)
            % Compute deviations from target
            devMean = mean(sampleSmallTemp) - meanReq;
            devSig = std(sampleSmallTemp) - stdevs;
            devTotal(j) = weights(1) * sum(devMean.^2) + weights(2) * sum(devSig.^2);
        end
        % Penalize bad spectra (set penalty to zero if this is not required)
        if penalty ~= 0
            for m=1:size(sampleSmall,1)
                devTotal(j) = devTotal(j) + sum(abs(exp(sampleSmallTemp(m,:))>exp(meanReq+3*stdevs'))) * penalty;
            end
        end
        
    elseif optType == 1
        [devTotal(j)] = KS_stat(PerTgt, emp_cdf, sampleSmallTemp, meanReq, stdevs);
    end
    
    % Scale factors for either type of optimization should not
    % exceed the maximum
    if (scaleFac(j) > maxScale)
        devTotal(j) = devTotal(j) + 1000000;
    end
    
    % Should cause improvement and record should not be repeated
    if (any(recID == j))
        devTotal(j) = 100000;
    end

end

end

function [ sumDn ] = KS_stat( periods, emp_cdf, sampleSmall, means, stdevs )
% calculate sum of all KS-test statistics 

sortedlnSa = [min(sampleSmall); sort(sampleSmall)];
norm_cdf = normcdf(sortedlnSa,repmat(means,size(sampleSmall,1)+1,1),repmat(stdevs,size(sampleSmall,1)+1,1));
Dn = max(abs(repmat(emp_cdf',1,length(periods)) - norm_cdf));
sumDn = sum(Dn);

end


