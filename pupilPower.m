classdef pupilPower < analysisCore
	%PUPILPOWER Calculate power for each trial from EDF file pupil data
	
	%------------------PUBLIC PROPERTIES----------%
	properties
		%> filename to use
		fileName char
		%> eyelink parsed edf data
		pupilData
		%> plot verbosity
		verbose = true
		%> normalise the pupil diameter to the baseline?
		normaliseBaseline logical = true
		%> remove mean of each trial  before computing FFT
		detrend logical = true
		%> linear detrend each trial before computing FFT
		detrendLinear logical = false
		%> normalise the plots of power vs luminance?
		normalisePowerPlots logical = true
		%> color map to use
		colorMap char = 'turbo';
		%> actual R G B luminance maxima for display, if [1 1 1] then use 0<->1
		%> floating point range
		maxLuminances double = [1 1 1]
		%> use hanning window?
		useHanning logical = false
		%> smooth the pupil data?
		smoothPupil logical = true;
		%> smoothing window in milliseconds
		smoothWindow double = 30;
		%> smooth method
		smoothMethod char = 'gaussian'
		%> draw error bars on raw pupil plots
		drawError logical = true
		%> error bars
		error char = 'SE';
		%> downsample raw pupil for plotting only (every N points)
		downSample double = 20;
		%> the calibration data from the display++
		calibrationFile = ''
		%> use simple luminance maxima or the linear regression
		simpleMode = false
		%> show 2nd harmonic plots
		plotHarmonics = false
		%> fitting function
		fit = 'smoothingspline'
		%> conversion to diameter? true/false | calibration value | measured
		%> diameter
		useDiameter = {false, 9250, 8}
	end
	
	properties (Hidden = true)
		%> default R G B luminance maxima, if [1 1 1] then use 0<->1
		%> floating point range, compatibility with older code, use
		%> maxLumiances
		defLuminances double = [1 1 1]
		%> choose which sub-variables to plot, empty plots all
		xpoints = []
		%> trial numbers to exclude
		excludeTrials = []
		%> show the frequencies
		showFrequencies = true
	end
	
	%------------------VISIBLE PROPERTIES----------%
	properties (SetAccess = {?analysisCore}, GetAccess = public)
		meanPowerValues
		varPowerValues
		meanPhaseValues
		varPhaseValues
		meanPupil
		varPupil
		meanTimes
		modifiedPupil 
		modifiedTimes
		meanF
		meanP
		varP
		SortedPupil struct
		taggingFrequency = []
		transitionTime;
	end
	
	%------------------PROTECTED PROPERTIES----------%
	properties (SetAccess = {?analysisCore}, GetAccess = public, Hidden = true)
		meanPowerValues0
		varPowerValues0
		meanPowerValues2
		varPowerValues2
		meanPhaseValues0
		varPhaseValues0
		meanPhaseValues2
		varPhaseValues2
		powerValues cell
		phaseValues cell
		powerValues0 cell
		phaseValues0 cell
		powerValues2 cell
		phaseValues2 cell
		metadata struct
		rawPupil cell
		rawTimes cell
		rawF cell
		rawP cell
		isLoaded logical = false
		isCalculated logical = false
		maxTime
	end
	
	%------------------PRIVATE PROPERTIES----------%
	properties (SetAccess = private, GetAccess = private)
		%> the monitor calibration object
		c
		%> processed luminance data fits
		l
		%> raw data removed, cannot reparse from EDF events.
		isRawDataRemoved = false
		%> allowed properties passed to object upon construction, see parseArgs
		allowedProperties = {'calibrationFile','useHanning','defLuminances','fileName','pupilData',...
			'normaliseBaseline','normalisePowerPlots','error','colorMap',...
			'maxLuminances','smoothPupil','smoothMethod','drawError','downSample','useDiameter'}
	end
	
	%=======================================================================
	methods
	%=======================================================================
		
		% ===================================================================
		%> @brief class constructor
		%>
		%> @param
		%> @return
		% ===================================================================
		function me = pupilPower(varargin)
			defaults.measureRange = [0.5667 0.5667 + (0.5667*5)];
			defaults.baselineWindow = [-0.1 0.1];
			defaults.plotRange = [];
			if ~exist('turbo.m','file')
				defaults.colorMap = 'jet';
			end
			varargin = optickaCore.addDefaults(varargin,defaults);
			me = me@analysisCore(varargin); %superclass constructor
			if nargin>0; me.parseArgs(varargin, me.allowedProperties); end
			
			if ~isempty(me.fileName)
				[p,f,~] = fileparts(me.fileName);
				if ~isempty(p) && (exist(p,'dir') == 7)
					me.rootDirectory = p;
				else
					me.rootDirectory = pwd;
				end
				me.name = f;
			else
				if isempty(me.name); me.name = 'pupilPower'; end
				me.rootDirectory = pwd;
				%run(me);
			end
		end
		
		% ===================================================================
		%> @brief validate 
		% ===================================================================
		function set.maxLuminances(me,value)
			if all( [1 3] == size(value) )
				me.maxLuminances = value;
			elseif all( [3 1] == size(value) )
				me.maxLuminances = value';
			else 
				me.maxLuminances = [1 1 1];
			end
		end
		
		% ===================================================================
		%> @brief run full analysis and plot the result
		%>
		%> @param force: reload the EDF and reparse
		%> @return
		% ===================================================================
		function [handles,data] = run(me, force)
			if ~me.simpleMode;loadCalibration(me); fitLuminances(me);end
			if isempty(me.l); me.simpleMode = true; end
			if ~exist('force','var') || isempty(force); force = false; end
			if ~isempty(me.pupilData);me.pupilData.useDiameter = me.useDiameter;end
			me.load(force);
			if isempty(me.metadata);warning('No data was loaded...');return;end
			if isfield(me.metadata.ana,'onFrames')
				me.taggingFrequency = (me.metadata.sM.screenVals.fps/me.metadata.ana.onFrames) / 2;
				me.transitionTime = me.metadata.ana.onFrames * (1/me.metadata.sM.screenVals.fps);
			else
				me.taggingFrequency = me.metadata.ana.frequency;
				me.transitionTime = (1/me.metadata.ana.frequency)/2;
			end
			me.calculate();
			if me.doPlots; [handles,data] = me.plot(); end
		end
		
		% ===================================================================
		%> @brief plot the parsed data
		%>
		%> @param
		%> @return
		% ===================================================================
		function [handles,data] = plot(me)
			if ~me.isCalculated; return; end
			
			[fixColor,fixName,fColor,varColor,varName,tColor,trlColor,trlColors,...
				tit,colorLabels,step,colorMin,colorMax] = makecolors(me);
			
			data.fixName = fixName;
			data.varName = varName;
			data.trlColors = trlColors;

			function spawnMe(src, ~)
				fnew = figure('Color',[1 1 1],'Units','normalized','Position',[0 0.5 1 0.5]);
				na = copyobj(src,fnew);
				na.Position = [0.1 0.1 0.8 0.8];
			end
			
			handles.h1=figure;figpos(2,[1000 500]);set(handles.h1,'Color',[1 1 1],'NumberTitle','off',...
				'Name',['pupilPower: ' me.pupilData.file],'Papertype','a4','PaperUnits','centimeters',...
				'PaperOrientation','landscape','Renderer','painters');
			switch varName
				case 'Grey'
					plotColor = [0.5 0.5 0.5];
				case 'Yellow'
					plotColor = [0.8 0.8 0];
				otherwise
					plotColor = zeros(1,3);	plotColor(1,tColor)	= 0.8;
			end
			switch fixName
				case 'Grey'
					lineColor = [0.5 0.5 0.5];
				case 'Yellow'
					lineColor = [0.8 0.8 0];
				otherwise
					lineColor = zeros(1,3);	lineColor(1,fColor)	= 0.8;
			end
			pCorrect = (length(me.pupilData.correct.idx)/length(me.pupilData.trials))*100;
			if me.simpleMode && max(me.maxLuminances) > 1
				mode = 'simple';
			elseif me.simpleMode && max(me.maxLuminances) == 1
				mode = 'none';
			else
				mode = 'full';
			end
			t2 = sprintf('%i / %i = %.2f%% | background: %s',...
				length(me.pupilData.correct.idx),length(me.pupilData.trials), ...
				pCorrect,num2str(me.metadata.ana.backgroundColor,'%.3f '));
			
			if isempty(me.xpoints)
				start = 1;
				finish = length(colorLabels);
				numVars	= finish;
			else
				start = me.xpoints(1);
				finish = me.xpoints(2);
				numVars = (finish-start) + 1;
			end
			
			cstep = trlColors(start:finish); csteps = cstep;
			csteps(numVars+1) = cstep(numVars);
			PL = stairs(1:numVars+1, csteps, 'Color',plotColor,'LineWidth',2);
			PL.Parent.FontSize = 11;
			PL.Parent.XTick = 1.5:1:numVars+0.5;
			PL.Parent.XTickLabel = colorLabels; 
			PL.Parent.XTickLabelRotation = 30;
			xlim([0.5 numVars+1.5])
			ax = axis;
			line([ax(1) ax(2)],[fixColor(1) fixColor(1)],'Color',lineColor,'Linewidth',2);
			if max(me.maxLuminances) == 1
				xlabel('Step (0 <-> 1)')
			else
				xlabel('Step (cd/m^2)')
			end
			ylim([min(csteps)-step(1) max(csteps)+step(1)])
			%set(gca,'ytick',colorMin-step:2*step:colorMax+step)
			ylabel('Luminance (cd/m^2)')
			title([tit t2]);
			box on; grid on;
			
			handles.h2=figure;figpos(1,[0.9 0.9],[],'%');set(handles.h2,'Color',[1 1 1],'NumberTitle','off',...
				'Name',['pupilPower: ' me.pupilData.file],'Papertype','a4','PaperUnits','centimeters',...
				'PaperOrientation','landscape','Renderer','painters');
			if me.showFrequencies
				tl = tiledlayout(handles.h2,2,3,'TileSpacing','tight');
				ax1 = nexttile(tl,[1 3]);
			else
				tl = tiledlayout(handles.h2,2,1,'TileSpacing','tight');
				ax1 = nexttile(tl);
			end
			ax1.ButtonDownFcn = @spawnMe;
			tl.Padding				= 'tight';
			tl.Title.String			= me.pupilData.file;
			tl.Title.Interpreter	= 'none';
			tl.Title.FontWeight		= 'bold';
			traceColor				= colormap(me.colorMap);
			traceColor_step			= floor(length(traceColor)/numVars);
			
			f = round(me.metadata.ana.onFrames) * (1 / me.metadata.sM.screenVals.fps);
			if isfield(me.metadata.ana,'flashFirst') && me.metadata.ana.flashFirst == true
				m = 0:2:100;
			else
				m = 1:2:101;
			end
			for i = 1 : floor(me.metadata.ana.trialDuration / f / 2) + 1
				rectangle('Position',[f*m(i) -10000 f 20000],'FaceColor',[0.8 0.8 0.8 0.3],'EdgeColor','none')
			end
			maxp = -inf;
			minp = inf;
			
			a = 0;
			for i = start : finish 
				hold on
				t = me.meanTimes{i};
				p = me.meanPupil{i};
				e = me.varPupil{i};
				
				if isempty(t); continue; end

				c = traceColor((a*traceColor_step)+1,:);
				
				if me.pupilData.sampleRate > 500
					idx = circshift(logical(mod(1:length(t),me.downSample)), -(me.downSample-1)); %downsample every N as less points to draw
					t(idx) = [];
					p(idx) = [];
					e(idx) = [];
				end
				
				if me.normaliseBaseline
					idx = t >= me.baselineWindow(1) & t <= me.baselineWindow(2);
					mn = mean(p(idx));
					p = p - mn;
				end
				
				idx = t >= me.measureRange(1) & t <= me.measureRange(2);
				if me.detrend
					m = mean(p(idx),'omitnan');
					if ~isnan(m); p = p - mean(p(idx)); end
				end
				
				idx = t >= me.measureRange(1) & t <= me.measureRange(2);
				maxp = max([maxp max(p(idx)+e(idx))]);
				minp = min([minp min(p(idx)-e(idx))]);

				if ~isempty(p)
					if me.drawError
						PL1 = analysisCore.areabar(t,p,e,c,0.2,...
							'Color', c, 'LineWidth', 2,'DisplayName',colorLabels{i});
						try
							row = dataTipTextRow('Color',repmat({num2str(trlColors(i))},length(t),1));
							PL1.plot.DataTipTemplate.DataTipRows(end+1) = row;
							PL1.plot.DataTipTemplate.DataTipRows(1).Label = 'Time';
							PL1.plot.DataTipTemplate.DataTipRows(2).Label = 'Power';
						end
					else
						PL1 = plot(t,p,'color', c,...
							'LineWidth', 1,'DisplayName',colorLabels{i});
						try
							PL1.DataTipTemplate.DataTipRows(1).Label = 'Time';
							PL1.DataTipTemplate.DataTipRows(2).Label = 'Power';
						end
					end 
					a = a + 1;
				end
				
			end
			
			line([me.measureRange(1) me.measureRange(1)],[minp maxp],...
				'Color',[0.2 0.2 0.2 0.8],'linestyle',':','LineWidth',3);
			line([me.measureRange(2) me.measureRange(2)],[minp maxp],...
				'Color',[0.2 0.2 0.2 0.8],'linestyle',':','LineWidth',3);
			
			data.minDiameter = minp;
			data.maxDiameter = maxp;
			data.diameterRange = maxp - minp;
			
			xlabel('Time (secs)')
			if me.useDiameter{1} == false
				ylabel('Pupil Diameter (area)')
			else
				ylabel('Pupil Diameter (mm)')
			end
			if me.normaliseBaseline
				title(['Normalised Pupil (mode: ' mode '|bg: ' num2str(me.metadata.ana.backgroundColor,'%.3f ') '): # Trials = ' num2str(me.metadata.ana.trialNumber) ' | Subject = ' me.metadata.ana.subject  ' | baseline = ' num2str(me.baselineWindow,'%.2f ') 'secs'  ' | Range = ' num2str(data.diameterRange,'%.2f')]);
			else
				title(['Raw Pupil (mode: ' mode '|bg: ' num2str(me.metadata.ana.backgroundColor,'%.3f ') '): # Trials = ' num2str(me.metadata.ana.trialNumber) ' | Subject = ' me.metadata.ana.subject  ' | Range = ' num2str(data.diameterRange,'%.2f')])
			end
			xlim([me.measureRange(1)-0.2 me.measureRange(2)+0.2]);
			if minp == 0; minp = -1;end
			if maxp==0; maxp = 1; end
			if minp <= 0
				ylim([minp+(minp/7) maxp+(maxp/7)]);
			else
				ylim([minp-(minp/7) maxp+(maxp/7)]);
			end
			legend(colorLabels(start:finish),'FontSize',10,'Location','northwest'); %'Position',[0.955 0.75 0.04 0.24]
			box on; grid on; 
			ax1.XMinorGrid = 'on';
			ax1.FontSize = 12;
			
			if me.showFrequencies
				ax2 = nexttile(tl);
				ax2.ButtonDownFcn = @spawnMe;
				maxP = 0;
				a=0;
				for i = start : finish %1: length(me.meanF)
					hold on
					c = traceColor((a*traceColor_step)+1,:);
					F = me.meanF{i};
					P = me.meanP{i};
					idx = F < 20;
					F = F(idx);
					P = P(idx);
					maxP = max([maxP max(P)]);
					PL2 = plot(F,P,'color', [c 0.6],...
						'LineWidth', 2,...
						'Marker','o','DisplayName',colorLabels{i},...
						'MarkerSize', 5,'MarkerFaceColor',traceColor((a*traceColor_step)+1,:),...
						'MarkerEdgeColor', 'none');
					try
						row = dataTipTextRow('Color',repmat({num2str(trlColors(i))},length(t),1));
						PL2.DataTipTemplate.DataTipRows(end+1) = row;
						PL2.DataTipTemplate.DataTipRows(1).Label = 'Frequency';
						PL2.DataTipTemplate.DataTipRows(2).Label = 'Power';
					end
					a = a + 1;
				end
				xlim([-0.1 floor(me.metadata.ana.frequency*4)]);
				if maxP==0; maxP=1; end
				ylim([0 maxP+(maxP/20)]);
				xlabel('Frequency (Hz)');
				ylabel('Power');
				if ~me.detrend && ~me.normaliseBaseline
					ax2.YScale = 'log';
					ylabel('Power [log]');
				end
				line([me.taggingFrequency me.taggingFrequency],[ax2.YLim(1) ax2.YLim(2)],...
					'Color',[0.3 0.3 0.3 0.5],'linestyle',':','LineWidth',2);
				if me.plotHarmonics
					line([me.taggingFrequency*2 me.taggingFrequency*2],[ax2.YLim(1) ax2.YLim(2)],...
						'Color',[0.3 0.3 0.3 0.5],'linestyle',':','LineWidth',2);
					line([0 0],[ax2.YLim(1) ax2.YLim(2)],...
						'Color',[0.3 0.3 0.3 0.5],'linestyle',':','LineWidth',2);
				end
				title(['FFT Power: range = ' num2str(me.measureRange,'%.2f ') 'secs | F = ' num2str(me.taggingFrequency) 'Hz\newlineHanning = ' num2str(me.useHanning)]);
				box on; grid on; grid minor;
				ax2.FontSize = 12;
			else
				ax2 = [];
			end
			
			if me.showFrequencies
				ax3 = nexttile(tl,[1 2]);
			else
				ax3 = nexttile(tl);
			end
			ax3.ButtonDownFcn = @spawnMe;
			is0=false;
			is2=false;
			hold on
			if exist('colororder','file')>0; colororder({'k','k'});end
			yyaxis right
			pv = me.meanPhaseValues(start:finish);
			if min(pv) < 0; pv = pv + abs(min(pv)); end
			phase1H = analysisCore.areabar(cstep,pv,...
				me.varPhaseValues(start:finish),[0.6 0.6 0.3],0.25,'LineWidth',1.5,'DisplayName','Phase-H1');
			try
				phase1H.plot.DataTipTemplate.DataTipRows(1).Label = 'Luminance';
				phase1H.plot.DataTipTemplate.DataTipRows(2).Label = 'Phase';
			end
			if me.plotHarmonics
				is2=true;
				hold on
				pv2 = me.meanPhaseValues2(start:finish);
				if min(pv2) < 0; pv2 = pv2 + abs(min(pv2)); end
				phase2H = analysisCore.areabar(cstep,pv2,...
				me.varPhaseValues2(start:finish),[0.6 0.6 0.6],0.25,'LineWidth',1,'DisplayName','Phase-H2');
				try
					phase2H.plot.DataTipTemplate.DataTipRows(1).Label = 'Luminance';
					phase2H.plot.DataTipTemplate.DataTipRows(2).Label = 'Phase';
				end
				mn = min([min(pv-me.varPhaseValues) min(pv2-me.varPhaseValues2)]);
				mx = max([max(pv+me.varPhaseValues) max(pv2+me.varPhaseValues2)]);
			else
				mn = min(pv-me.varPhaseValues);
				mx = max(pv+me.varPhaseValues); 
			end
			
			ylim([mn mx]);
			%PL3b = plot(trlColors,rad2deg(A),'k-.','Color',[0.6 0.6 0.3],'linewidth',1);
			ylabel('Phase (deg)');
			data.X=cstep;
			data.phaseY=me.meanPhaseValues(start:finish);
			data.phaseE=me.varPhaseValues(start:finish);
			
			box on; grid on;
			
			yyaxis left
			hold on
			if me.normalisePowerPlots
				m0 = me.meanPowerValues0(start:finish) / max(me.meanPowerValues0(start:finish));
				e0 = me.varPowerValues0(start:finish) / max(me.meanPowerValues0(start:finish));
			else
				m0 = me.meanPowerValues0(start:finish);
				e0 = me.varPowerValues0(start:finish);
			end
			data.m0=m0;
			data.e0=e0;
			if me.plotHarmonics && max(me.meanPowerValues0) > 0.1 % only if there is a significant response
				is0 = true;
				h0PH = analysisCore.areabar(cstep,m0,e0,[0.5 0.5 0.7],0.1,...
					'Marker','o','LineWidth',1,'DisplayName','H0');
				try %#ok<*TRYNC>
					h0PH.plot.DataTipTemplate.DataTipRows(1).Label = 'Luminance';
					h0PH.plot.DataTipTemplate.DataTipRows(2).Label = 'Power';
				end
			end
			if me.normalisePowerPlots
				m2 = me.meanPowerValues2(start:finish) / max(me.meanPowerValues2(start:finish));
				e2 = me.varPowerValues2(start:finish) / max(me.meanPowerValues2(start:finish));
			else
				m2 = me.meanPowerValues2(start:finish);
				e2 = me.varPowerValues2(start:finish);
			end
			data.m2=m2';
			data.e2=e2';
			if me.plotHarmonics && max(me.meanPowerValues2) > 0.1 % only if there is a significant response
				is2 = true;
				h2PH = analysisCore.areabar(cstep,m2,e2,[0.7 0.4 0],0.1,...
					'Marker','o','LineWidth',1,'DisplayName','H2');
				try %#ok<*TRYNC>
					h2PH.plot.DataTipTemplate.DataTipRows(1).Label = 'Luminance';
					h2PH.plot.DataTipTemplate.DataTipRows(2).Label = 'Power';
				end
			end
			
			if me.normalisePowerPlots
				m = me.meanPowerValues(start:finish) / max(me.meanPowerValues(start:finish));
				e = me.varPowerValues(start:finish) / max(me.meanPowerValues(start:finish));
			else
				m = me.meanPowerValues(start:finish);
				e = me.varPowerValues(start:finish);
			end
			m = m';
			e = e';
			data.m=m;
			data.e=e;
			
			xx = linspace(min(cstep),max(cstep),500);
			warning off
			[f, gof] = fit(cstep',m',me.fit);
			disp(gof)
			warning on
			yy = feval(f,xx);
			ymin = find(yy==min(yy));
			ymin = xx(ymin);
			
			idx = find(m==min(m));
			minC = cstep(idx);
			ratio = fixColor / minC;
			ratio2 = fixColor / ymin;
			
			h1PH = analysisCore.areabar(cstep,m,e,[0.7 0.2 0.2],0.2,...
				'LineWidth',2,'DisplayName','H1');
			try
				h1PH.plot.DataTipTemplate.DataTipRows(1).Label = 'Luminance';
				h1PH.plot.DataTipTemplate.DataTipRows(2).Label = 'Power';
			end
			fitH = plot(xx,yy,'r--','LineWidth',1,'DisplayName','H1-Fit');
			
			if is0
				mx = max([max(m+e) max(m0+e0)]);
				mn = min([min(m-e) min(m0-e0)]);
			else
				mx = max(m+e);
				mn = min(m-e);
			end
			ylim([mn mx]);
			pr = (m .* m0);
			pr = (pr / max(pr)) * mx;
			
			data.minColor = minC;
			data.ratio = ratio;
			data.ratio2 = ratio2;
			
			ax3.FontSize = 12;
			ax3.XTick = cstep;
			ax3.XTickLabel = colorLabels(start:finish); 
			ax3.XTickLabelRotation = 45;
			pad = max(diff(cstep))/10;
			ax3.XLim = [ min(cstep) - pad max(cstep) + pad];
			
			if fixColor <= max(cstep) && fixColor >= min(cstep)
				line([fixColor fixColor],[ax3.YLim(1) ax3.YLim(2)],...
				'lineStyle',':','Color',[0.3 0.3 0.3 0.5],'linewidth',2);
			end

			if ymin <= max(cstep) && ymin >= min(cstep)
				line([ymin ymin],[ax3.YLim(1) ax3.YLim(2)],...
				'lineStyle',':','Color',[1.0 0.5 0.1 0.5],'linewidth',2);
			end

			if max(me.maxLuminances) == 1
				xlabel('LuminanceStep (0 <-> 1)')
			else
				xlabel('Luminance Step (cd/m^2)')
			end
			if me.normalisePowerPlots
				ylabel('Normalised Power')
			else
				ylabel('Power')
			end
			tit = sprintf('Harmonic Power: %s | %s Min@H1 = %.2f & Ratio = %.2f/%.2f', ...
				tit, varName, data.minColor, data.ratio, data.ratio2);
			title(tit);
			
			if is2 && is0
				leg = [h1PH.plot,phase1H.plot,fitH,h2PH.plot,phase2H.plot,h0PH.plot];
			elseif is2 && ~is0
				leg = [h1PH.plot,phase1H.plot,fitH,h2PH.plot,phase2H.plot];
			elseif ~is2 && is0
				leg = [h1PH.plot,phase1H.plot,fitH,h0PH.plot];
			else
				leg = [h1PH.plot,phase1H.plot,fitH];
			end
			legend(leg,'FontSize',10,'Location','southeast'); %'Position',[0.9125 0.2499 0.0816 0.0735],
			
			box on; grid on;
			
			handles.ax1 = ax1;
			handles.ax2 = ax2;
			handles.ax3 = ax3;
			if exist('PL1','var');handles.PL1 = PL1;end
			if exist('PL2','var');handles.PL2 = PL2;end
			if exist('PL3a','var');handles.PL3a = phase1H;end
			if exist('h0PH','var');handles.PL3 = h0PH;end
			if exist('h1PH','var'); handles.PL4 = h1PH;end
			if exist('h0h1PH','var');handles.PL5 = h0h1PH;end
			if exist('h2PH','var');handles.PL6 = h2PH;end
			if exist('phase2H','var'); handles.PL7 = phase1H;end
			if exist('h0h1PH','var');handles.PL8 = h0h1PH;end
			drawnow;
			figure(handles.h2);
			fontsize(14,'points');
			fontname('Source Sans 3');
		end

		% ===================================================================
		%> @brief 
		%>
		%> @param
		%> @return
		% ===================================================================
		function plotIndividualTrials(me,idx)
			if isempty(me.modifiedPupil); warning('No data yet analysed');return;end
			numVars					= length(me.modifiedPupil);
			if ~exist('idx','var'); idx = 1 : numVars; end
			figure; hold on; colormap(me.colorMap);
			box on; grid on
			xlabel('Time (secs)')
			ylabel('Pupil Diameter')
			traceColor				= colormap(me.colorMap);
			traceColor_step			= floor(length(traceColor)/numVars);
			for i = idx
				cl = traceColor(((i-1)*traceColor_step)+1,:);
				x = cell2mat(me.modifiedTimes{i}(1:end)')';
				y = cell2mat(me.modifiedPupil{i}(1:end)')';
				plot(x, y, 'Color', cl,'LineWidth',2);
				drawnow;
				WaitSecs(1);
			end
		end
		
		% ===================================================================
		%> @brief save
		%>
		%> @param file filename to save to
		%> @return
		% ===================================================================
		function save(me, file)
			
			me.pupilData.removeRawData();
			save(file,'me','-v7.3');

		end
		
		% ===================================================================
		%> @brief save
		%>
		%> @param file filename to save to
		%> @return
		% ===================================================================
		function fitLuminances(me)
			if isempty(me.c); loadCalibration(me); end
			if isa(me.c,'calibrateLuminance') && isempty(me.l) 
				
				l.igray		= me.c.inputValues(1).in; %#ok<*PROP>
				l.ired		= me.c.inputValues(2).in;
				l.igreen	= me.c.inputValues(3).in;
				l.iblue		= me.c.inputValues(4).in;
				l.x			= me.c.ramp;

				[l.fx, l.fgray]	= analysisCore.linearFit(l.x, l.igray);
				[~, l.fred]		= analysisCore.linearFit(l.x, l.ired);
				[~, l.fgreen]	= analysisCore.linearFit(l.x, l.igreen);
				[~, l.fblue]	= analysisCore.linearFit(l.x, l.iblue);
				l.fred(l.fred<0)=0; l.fgreen(l.fgreen<0)=0; l.fblue(l.fblue<0)=0; l.fgray(l.fgray<0)=0;
				me.l = l;
			end
		end
		
		% ===================================================================
		%> @brief save
		%>
		%> @param file filename to save to
		%> @return
		% ===================================================================
		function [x1, y1, x2, y2] = getLuminances(me, value, from, to)
			if isempty(me.l); me.fitLuminances; end
			l = me.l;
			fx = l.fx;
			switch from
				case 'red'
					fy = l.fred;
				case 'green'
					fy = l.fgreen;
				case 'blue'
					fy = l.fblue;
				case 'gray'
					fy = l.fgray;
			end
			
			switch to
				case 'red'
					ty = l.fred;
				case 'green'
					ty = l.fgreen;
				case 'blue'
					ty = l.fblue;
				case 'gray'
					ty = l.fgray;
			end
			
			[ix,~,~] = analysisCore.findNearest(fx, value);
			x1 = fx(ix);
			y1 = fy(ix);
			[ix,~,~] = analysisCore.findNearest(ty, y1);
			x2 = fx(ix);
			y2 = ty(ix);
		end
		
		% ===================================================================
		%> @brief save
		%>
		%> @param file filename to save to
		%> @return
		% ===================================================================
		function [y, x] = getLuminance(me, value, color)
			if isempty(me.l); me.fitLuminances; end
			l = me.l;
			fx = l.fx;
			if ~exist('color','var') && length(value) == 3
				fy{1} = l.fred;
				fy{2} = l.fgreen;
				fy{3} = l.fblue;
				for i = 1:3
					[ix,~,~] = analysisCore.findNearest(fx, value(i));
					x(i) = fx(ix);
					y(i) = fy{i}(ix);
				end
			else
				switch color
					case 'red'
						fy = l.fred;
					case 'green'
						fy = l.fgreen;
					case 'blue'
						fy = l.fblue;
					case 'gray'
						fy = l.fgray;
				end
				for i = 1:length(value)
					[ix,~,~] = analysisCore.findNearest(fx, value(i));
					x(i) = fx(ix);
					y(i) = fy(ix);
				end
			end
			y( y < 0 ) = 0;
		end
	
		% ===================================================================
		%> @brief make the color variables used in plotting
		%>
		%> @param
		%> @return
		% ===================================================================
		function [fixColor,fixName,fColor,varColor,varName,tColor,trlColor,...
				trlColors,tit,colorLabels,step,colorMin,colorMax] = ...
				makecolors(me,fc,cs,ce,vals)
			if ~exist('fc','var') || isempty(fc); fc = me.metadata.ana.colorFixed; end
			if ~exist('cs','var') || isempty(cs); cs = me.metadata.ana.colorStart; end
			if ~exist('ce','var') || isempty(ce); ce = me.metadata.ana.colorEnd; end
			if ~exist('vals','var') || isempty(vals); vals = me.metadata.seq.nVar.values'; end
			if size(me.maxLuminances,1) > 1; me.maxLuminances=me.maxLuminances';end
			cNames = {'Red';'Green';'Blue';'Yellow';'Grey';'Cyan';'Purple'};
			
			fColor=find(fc > 0); %get the position of not zero
			if length(fColor) == 1 && fColor <= 3
				
			elseif length(fColor) == 2 && all([1 2] == fColor)
				fColor = 4;
			elseif length(fColor) == 2 && all([1 3] == fColor)
				fColor = 7;
			elseif length(fColor) == 2 && all([2 3] == fColor)
					fColor = 6;
			elseif length(fColor) == 3 && isequal(fc(1),fc(2),fc(3))
				fColor = 5;
			else
				warning('Cannot Define fixed color!');
			end
			if me.simpleMode
				fix = fc .* me.maxLuminances;
			else
				fix = me.getLuminance(fc);
			end
			fixName = cNames{fColor};
			switch fixName
				case 'Grey'
					fixColor = fix(1) + fix(2) + fix(3);
				case 'Yellow'
					fixColor = fix(1) + fix(2);
				otherwise
					fixColor = sum(fix(fColor));
			end
			
			if me.simpleMode
				cE = ce .* me.maxLuminances;
				cS = cs .* me.maxLuminances;
			else
				cE = me.getLuminance(ce);
				cS = me.getLuminance(cs);
			end
			vColor=find(ce > 0); %get the position of not zero
			if length(vColor)==3 && all([1 2 3] == vColor); vi = 5;
			elseif length(vColor)==2 && all([1 2] == vColor); vi = 4; 
			elseif length(vColor)==2 && all([1 3] == vColor); vi = 7; 
			elseif length(vColor)==2 && all([2 3] == vColor); vi = 6;
			else; vi = vColor;
			end
			varName = cNames{vi};
			varColor = sum(cS(vColor));
			
			if me.simpleMode
				vals = cellfun(@(x) x .* me.maxLuminances, vals, 'UniformOutput', false);
			else
				vals = cellfun(@(x) getLuminance(me,x), vals, 'UniformOutput', false);
			end
			trlColor=cell2mat(vals);
			tit = num2str(fix,'%.2f ');
			tit = regexprep(tit,'0\.00','0');
			tit = ['Fix color (' fixName ') = ' tit ' | Var color (' varName ')'];
			colorChange= cE - cS;
			tColor=find(colorChange~=0); %get the position of not zero
			step=abs(colorChange(tColor)/me.metadata.ana.colorStep);
			switch varName
				case 'Yellow'
					trlColors = trlColor(:,1)' + trlColor(:,2)';
					colorMin = min(trlColor(:,1)) + min(trlColor(:,2));
					colorMax = max(trlColor(:,1)) + max(trlColor(:,2));
				otherwise
					trlColors = trlColor(:,tColor)';
					colorMax=max(trlColor(:,tColor));
					colorMin=min(trlColor(:,tColor));
			end
			
			colorLabels = num2cell(trlColors);
			colorLabels = cellfun(@(x) num2str(x,'%.2f'), colorLabels, 'UniformOutput', false);
			
		end
		
		% ===================================================================
		%> @brief do the FFT
		%>
		%> @param p the raw signal
		%> @return 
		% ===================================================================
		function [P, f, A, p1, p0, p2, A0, A2] = doFFT(me,p)	
			useX = true;
			L = length(p);
			if me.useHanning
				win = hanning(L, 'periodic');
				P = fft(p.*win');
			else
				P = fft(p);
			end
			
			if useX
				Pi = fft(p);
				P = abs(Pi/L);
				P=P(1:floor(L/2)+1);
				P(2:end-1) = 2*P(2:end-1);
				f = me.pupilData.sampleRate * (0:(L/2))/L;
			else
				Pi = fft(p);
				NumUniquePts = ceil((L+1)/2);
				P = abs(Pi(1:NumUniquePts));
				f = (0:NumUniquePts-1)*me.pupilData.sampleRate/L;
			end
			
			idx = analysisCore.findNearest(f, me.taggingFrequency);
			p1 = P(idx);
			A = angle(Pi(idx));
			idx = analysisCore.findNearest(f, 0);
			p0 = P(idx);
			A0 = angle(Pi(idx));
			idx = analysisCore.findNearest(f, me.taggingFrequency*2);
			p2 = P(idx);
			A2 = angle(Pi(idx));
				
		end
		
	end
	
	
	%=======================================================================
	methods (Access = protected) %------------------PRIVATE METHODS
	%=======================================================================
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function load(me, force)
			if ~exist('force','var') || isempty(force); force = false; end
			if me.isLoaded && ~force; return; end
			try
				if ~isempty(me.fileName)
					me.pupilData=eyelinkAnalysis('file',me.fileName,'dir',me.rootDirectory);
				else
					me.pupilData=eyelinkAnalysis;
					me.fileName = me.pupilData.file;
					me.rootDirectory = me.pupilData.dir;
				end
				[~,fn] = fileparts(me.pupilData.file);
				if isempty(fn) || ~exist([me.pupilData.dir,filesep,fn,'.mat'],'file'); warning('No file specified!');return;end
				me.metadata = load([me.pupilData.dir,filesep,fn,'.mat']); %load .mat of same filename with .edf
				if isa(me.metadata.sM,'screenManager') && ~isempty(me.metadata.sM.gammaTable)
					if ~isempty(me.metadata.sM.gammaTable.inputValuesTest)
						l = me.metadata.sM.gammaTable.inputValuesTest;
					else
						l = me.metadata.sM.gammaTable.inputValues;
					end
					me.maxLuminances(1) = l(2).in(end);
					me.maxLuminances(2) = l(3).in(end);
					me.maxLuminances(3) = l(4).in(end);
				elseif max(me.defLuminances) > 1
					me.maxLuminances = me.defLuminances;
				end
				
				me.pupilData.correctValue	= 1;
				me.pupilData.incorrectValue = -100;
				me.pupilData.breakFixValue	= -1;
				me.pupilData.plotRange = [-0.5 3.5];
				me.pupilData.measureRange = me.measureRange;
				me.pupilData.pixelsPerCm = me.metadata.sM.pixelsPerCm;
				me.pupilData.distance = me.metadata.sM.distance;
				me.pupilData.useDiameter = me.useDiameter;
				
				fprintf('\n<strong>--->>></strong> LOADING raw EDF data: \n')
				parseSimple(me.pupilData);
				me.maxTime = max(me.pupilData.correct.timeRange(:,2));
				me.pupilData.removeRawData();me.isRawDataRemoved=true;
				me.isLoaded = true;
			catch ME
				getReport(ME);
				me.isLoaded = false;
				rethrow(ME)
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function calculate(me)
			if ~me.isLoaded; return; end
			Fs1 = me.pupilData.sampleRate; % Sampling frequency
			T1 = 1/Fs1; % Sampling period
			smoothSamples = me.smoothWindow / (T1 * 1e3);
			me.SortedPupil = struct();
			me.powerValues={}; me.phaseValues={};
			me.powerValues0={};	me.phaseValues0={};
			me.powerValues2={};	me.phaseValues2={};
			me.rawP = {}; me.rawF = {}; me.rawPupil = {}; me.rawTimes={};
			vars = unique(me.metadata.seq.outIndex);
			idx = me.pupilData.correct.idx;
			idx = setdiff(idx, me.excludeTrials);
			thisTrials = me.pupilData.trials(idx);
			if isa(me.metadata.seq,'stimulusSequence')
				minTrials = me.metadata.seq.minBlocks;
			else
				minTrials = me.metadata.seq.minTrials;
			end
			b = zeros(1,length(vars));
			for i=1:length(thisTrials)
				a=thisTrials(i).variable;
				b(a) = b(a) + 1;
				me.SortedPupil.pupilTrials{a}{b(a)}=thisTrials(i);
				me.SortedPupil.anaTrials{a}{b(a)}=me.metadata.ana.trial(thisTrials(i).correctedIndex);
			end
			
			if me.measureRange(2) > me.maxTime || diff(me.measureRange) == 0
				mult = floor(me.maxTime / me.transitionTime);
				if mod(mult,2); mult = mult - 1; end
				if mult > 3
					me.measureRange = [me.transitionTime*2 me.transitionTime*mult];
				else
					me.measureRange = [0 me.transitionTime*mult];
				end
			end
			
			lModel = fittype('a*(sin(x-pi))+b*((x-10)^2)+c*(1)');
			thisTrials = me.SortedPupil.pupilTrials;
			numvars=minTrials; %Number of trials
			t1=tic;
			for currentVar=1:length(thisTrials)
				numBlocks = length(thisTrials{currentVar});
				k = 1;	F = [];	P = [];	Pu = []; Ti = []; minTs = []; maxTs = [];
				for currentBlock=1:numBlocks
					if ~isempty(thisTrials{currentVar}{currentBlock}.variable)
						p = thisTrials{currentVar}{currentBlock}.pa;
						t = thisTrials{currentVar}{currentBlock}.times / 1e3;
						if me.smoothPupil
							p = smoothdata(p,me.smoothMethod,smoothSamples);
						end		
						me.rawPupil{currentVar}{currentBlock} = p;
						me.rawTimes{currentVar}{currentBlock} = t;

						minTs(k)=min(t);
						maxTs(k)=max(t);

						if me.normaliseBaseline
							idx = t >= me.baselineWindow(1) & t <= me.baselineWindow(2);
							mn = mean(p(idx));
							p = p - mn;
						end

						idx = t >= me.measureRange(1) & t <= me.measureRange(2);
						if ~any(idx)
							p=NaN;P=NaN;f=NaN;A=NaN;p0=NaN;p1=NaN;p2=NaN;A0=NaN;A2=NaN;
						else
							p = p(idx);
							t = t(idx);
							if me.detrendLinear
								warning off;
								mf = fit(t',p','poly1');
								pm = feval(mf,t);
								p = p - pm;
								warning on;
							end
							if me.detrend
								p = p - mean(p);
							end
							[P,f,A,p1,p0,p2,A0,A2] = me.doFFT(p);
						end

						me.modifiedPupil{currentVar}{currentBlock} = p;
						me.modifiedTimes{currentVar}{currentBlock} = t;
						me.powerValues{currentVar}(currentBlock) = p1; %get the pupil power of tagging frequency
						me.phaseValues{currentVar}(currentBlock) = rad2deg(A);
						me.powerValues0{currentVar}(currentBlock) = p0; %get the pupil power of 0 harmonic
						me.powerValues2{currentVar}(currentBlock) = p2; %get the pupil power of 0 harmonic
						me.phaseValues0{currentVar}(currentBlock) = rad2deg(A0);
						me.phaseValues2{currentVar}(currentBlock) = rad2deg(A2);
						me.rawF{currentVar}{currentBlock} = f;
						me.rawP{currentVar}{currentBlock} = P;

						rawFramef(k)=size(me.rawF{currentVar}{currentBlock},2);
						k=k+1;
					end
				end
				rawFramefMin(currentVar)=min(rawFramef);
				clear P;
				for currentBlock=1:numBlocks
					F(currentBlock,:)=me.rawF{currentVar}{currentBlock}(1,1:rawFramefMin(currentVar));
					P(currentBlock,:)=me.rawP{currentVar}{currentBlock}(1,1:rawFramefMin(currentVar));
					t = me.rawTimes{currentVar}{currentBlock};
					p = me.rawPupil{currentVar}{currentBlock};
					idx = t >= max(minTs) & t <= min(maxTs);
					Ti(currentBlock,:) = t(idx);
					Pu(currentBlock,:) = p(idx);
				end

				me.meanF{currentVar,1} = F(1,:);
				[p,e] = analysisCore.stderr(P,me.error,false,0.05,1);
				me.meanP{currentVar,1}=p;
				me.varP{currentVar,1}=e;

				me.meanTimes{currentVar,1} = Ti(1,:);
				[p,e] = analysisCore.stderr(Pu,me.error,false,0.05,1);
				me.meanPupil{currentVar,1}=p;
				me.varPupil{currentVar,1}=e;
			end
			fprintf('---> pupilPower FFT calculation took %.3f secs\n',toc(t1));
			
			clear p e
			pV=me.powerValues;
			for i = 1:length(pV)
				pV{i}(pV{i}==0) = NaN;
				[p(i),e(i)] = analysisCore.stderr(pV{i},me.error,false,0.05);
			end
			me.meanPowerValues = p';
			me.varPowerValues = e';
			me.varPowerValues(me.varPowerValues==inf)=0;
			
			clear p e
			pH=me.phaseValues;
			for i = 1:length(pH)
				pH{i}(pH{i}==0) = NaN;
				[p(i),e(i)] = analysisCore.stderr(pH{i},me.error,false,0.05);
			end
			me.meanPhaseValues = p';
			me.varPhaseValues = e';
			me.varPhaseValues(me.varPhaseValues==inf)=0;
			
			clear p e
			pV0=me.powerValues0;
			for i = 1:length(pV0)
				pV0{i}(pV0{i}==0) = NaN;
				[p(i),e(i)] = analysisCore.stderr(pV0{i},me.error,false,0.05);
			end
			me.meanPowerValues0 = p';
			me.varPowerValues0 = e';
			me.varPowerValues0(me.varPowerValues0==inf)=0;
			
			clear p e
			pH=me.phaseValues0;
			for i = 1:length(pH)
				pH{i}(pH{i}==0) = NaN;
				[p(i),e(i)] = analysisCore.stderr(pH{i},me.error,false,0.05);
			end
			me.meanPhaseValues0 = p';
			me.varPhaseValues0 = e';
			me.varPhaseValues0(me.varPhaseValues0==inf)=0;
			
			clear p e
			pV2=me.powerValues2;
			for i = 1:length(pV2)
				pV2{i}(pV2{i}==0) = NaN;
				[p(i),e(i)] = analysisCore.stderr(pV2{i},me.error,false,0.05);
			end
			me.meanPowerValues2 = p';
			me.varPowerValues2 = e';
			me.varPowerValues2(me.varPowerValues0==inf)=0;
			
			clear p e
			pH=me.phaseValues2;
			for i = 1:length(pH)
				pH{i}(pH{i}==0) = NaN;
				[p(i),e(i)] = analysisCore.stderr(pH{i},me.error,false,0.05);
			end
			me.meanPhaseValues2 = p';
			me.varPhaseValues2 = e';
			me.varPhaseValues2(me.varPhaseValues2==inf)=0;
			
			me.isCalculated = true;
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function loadCalibration(me)
			if (isempty(me.c) || ~isa(me.c,'calibrateLuminance')) && exist(me.calibrationFile,'file')
				in = load(me.calibrationFile);
				fprintf('--->>> Using %s calibration and max luminances: ',me.calibrationFile);
				me.c = in.c; clear in;
				me.maxLuminances = me.c.maxLuminances(2:4);
				fprintf('%.3f ',me.maxLuminances); fprintf('\n\n');
			end
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function closeUI(me, varargin)
			try delete(me.handles.parent); end %#ok<TRYNC>
			me.handles = struct();
			me.openUI = false;
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function makeUI(me, varargin) %#ok<INUSD>
			disp('Feature not finished yet...')
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function updateUI(me, varargin) %#ok<INUSD>
			disp('Feature not finished yet...')
		end
		
		% ===================================================================
		%> @brief
		%>
		%> @param
		%> @return
		% ===================================================================
		function notifyUI(me, varargin) %#ok<INUSD>
			disp('Feature not finished yet...')
		end
		
	end
end

