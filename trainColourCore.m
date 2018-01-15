function trainColourCore(ana)

global lJ

if exist('lJ','var') && isa(lJ,'arduinoManager')
	lJ.close;
end

lJ = arduinoManager;
lJ.open;

fprintf('\n--->>> trainColour Started: ana UUID = %s!\n',ana.uuid);

%===================Initiate out metadata===================
ana.date = datestr(datetime);
ana.version = Screen('Version');
ana.computer = Screen('Computer');

%===================experiment parameters===================
if ana.debug
	ana.screenID = 0;
else
	ana.screenID = max(Screen('Screens'));%-1;
end

%===================Make a name for this run===================
pf='Train_';
if ~isempty(ana.subject)
	nameExp = [pf ana.subject];
	c = sprintf(' %i',fix(clock()));
	nameExp = [nameExp c];
	ana.nameExp = regexprep(nameExp,' ','_');
else
	ana.nameExp = 'debug';
end

cla(ana.plotAxis1);
cla(ana.plotAxis2);
cla(ana.plotAxis3);

try
	PsychDefaultSetup(2);
	Screen('Preference', 'SkipSyncTests', 0);
	%===================open our screen====================
	sM = screenManager();
	sM.screen = ana.screenID;
	sM.windowed = ana.windowed;
	sM.pixelsPerCm = ana.pixelsPerCm;
	sM.distance = ana.distance;
	sM.debug = ana.debug;
	sM.blend = 1;
	sM.bitDepth = 'FloatingPoint32Bit';
	if exist(ana.gammaTable, 'file')
		load(ana.gammaTable);
		if isa(c,'calibrateLuminance')
			sM.gammaTable = c;
		end
		clear c;
		if ana.debug
			sM.gammaTable.plot
		end
	end
	sM.backgroundColour = ana.backgroundColor;
	sM.open; % OPEN THE SCREEN
	fprintf('\n--->>> ColourTrain Opened Screen %i : %s\n', sM.win, sM.fullName);
	
	%===========================set up stimuli====================
	circle1 = discStimulus;
	circle2 = discStimulus;
	circle1.sigma = ana.sigma1;
	circle2.sigma = ana.sigma2;
	circle1.size = ana.circle1Diameter;
	circle2.size = ana.circle2Diameter;
	circle1.colour = ana.colour1;
	circle2.colour = ana.colour2;
	
	vals = [-ana.positionXY(1) +ana.positionXY(1)];
	circle1.xPosition = vals(1);
	circle2.xPosition = vals(2);
	circle1.yPosition = ana.positionXY(2);
	circle2.yPosition = ana.positionXY(2);
	
	setup(circle1,sM);
	setup(circle2,sM);
	
	%============================SET UP VARIABLES=====================================
	
	seq = stimulusSequence;
	seq.nVar(1).name = 'xPosition';
	seq.nVar(1).stimulus = 1;
	seq.nVar(1).values = vals;
	seq.nBlocks = ana.trialNumber;
	seq.initialise();
	ana.nTrials = seq.nRuns;
	fprintf('--->>> Train # Trials: %i; # FPS: %i \n',seq.nRuns, sM.screenVals.fps);
	WaitSecs('YieldSecs',0.25);
	
	%==============================setup eyelink==========================
	ana.strictFixation = true;
	eL = eyelinkManager('IP',[]);
	fprintf('--->>> Train eL setup starting: %s\n', eL.fullName);
	eL.isDummy = ana.isDummy; %use dummy or real eyelink?
	eL.name = ana.nameExp;
	eL.saveFile = [ana.nameExp '.edf'];
	eL.recordData = true; %save EDF file
	eL.sampleRate = ana.sampleRate;
	eL.remoteCalibration = false; % manual calibration?
	eL.calibrationStyle = ana.calibrationStyle; % calibration style
	eL.exclusionZone = ana.exclusionZone;
	eL.modify.calibrationtargetcolour = [1 1 1];
	eL.modify.calibrationtargetsize = 1;
	eL.modify.calibrationtargetwidth = 0.05;
	eL.modify.waitformodereadytime = 500;
	eL.modify.devicenumber = -1; % -1 = use any keyboard
	% X, Y, FixInitTime, FixTime, Radius, StrictFix
	updateFixationValues(eL, ana.fixX, ana.fixY, ana.firstFixInit,...
		ana.firstFixTime, ana.firstFixDiameter, ana.strictFixation);
	
	%sM.verbose = true; eL.verbose = true; sM.verbosityLevel = 10; eL.verbosityLevel = 4; %force lots of log output
	
	initialise(eL, sM); %use sM to pass screen values to eyelink
	setup(eL); % do setup and calibration
	fprintf('--->>> Train eL setup complete: %s\n', eL.fullName);
	WaitSecs('YieldSecs',0.5);
	getSample(eL); %make sure everything is in memory etc.
	
	% initialise our trial variables
	plotVals.t1 = [];
	plotVals.p1 = [];
	plotVals.p2 = [];
	plotVals.t2 = [];
	plotVals.p3 = [];
	ana.trialDuration = 1;
	ana.nSuccess = 0;
	ana.nFixBreak = 0;
	ana.nInitiateBreak = 0;
	ana.nTotal = 0;
	ana.runningPerformance = [];
	tReaction = 0;
	tL = timeLogger();
	tL.screenLog.beforeDisplay = GetSecs();
	tL.screenLog.stimTime(1) = 1;
	powerValues = [];
	breakLoop = false;
	ana.trial = struct();
	excludedN = 0;
	tick = 1;
	halfisi = sM.screenVals.halfisi;
	Priority(MaxPriority(sM.win));
	
	while seq.thisRun <= seq.nRuns && ~breakLoop
		%=========================MAINTAIN INITIAL FIXATION==========================
		fprintf('\n===>>> Train START Trial = %i / %i | %s, %s\n', seq.thisRun, seq.nRuns, sM.fullName, eL.fullName);
		resetFixation(eL);
		updateFixationValues(eL, ana.fixX, ana.fixY, ana.firstFixInit,...
			ana.firstFixTime, ana.firstFixDiameter, ana.strictFixation);
		trackerClearScreen(eL);
		%trackerDrawExclusion(eL);
		trackerDrawFixation(eL); %draw fixation window on eyelink computer
		edfMessage(eL,'V_RT MESSAGE END_FIX END_RT');  %this 3 lines set the trial info for the eyelink
		edfMessage(eL,['TRIALID ' num2str(seq.outIndex(seq.thisRun))]);  %obj.getTaskIndex gives us which trial we're at
		startRecording(eL);
		statusMessage(eL,'INITIATE FIXATION...');
		fixated = '';
		ListenChar(2);
		fprintf('===>>> Train initiating fixation to start run...\n');
		syncTime(eL);
		while ~strcmpi(fixated,'fix') && ~strcmpi(fixated,'breakfix')
			drawCross(sM,0.4,[1 1 1 1],ana.fixX,ana.fixY);
			getSample(eL);
			fixated=testSearchHoldFixation(eL,'fix','breakfix');
			[keyIsDown, ~, keyCode] = KbCheck(-1);
			if keyIsDown == 1
				rchar = KbName(keyCode); if iscell(rchar);rchar=rchar{1};end
				switch lower(rchar)
					case {'c'}
						fprintf('===>>> Train recalibrate pressed!\n');
						fixated = 'breakfix';
						stopRecording(eL);
						setOffline(eL);
						trackerSetup(eL);
						WaitSecs('YieldSecs',2);
					case {'d'}
						fprintf('===>>> Train drift correct pressed!\n');
						fixated = 'breakfix';
						stopRecording(eL);
						driftCorrection(eL);
						WaitSecs('YieldSecs',2);
					case {'escape'}
						fprintf('===>>> Train escape pressed!!!\n');
						fixated = 'breakfix';
						breakLoop = true;
				end
			end
			Screen('Flip',sM.win); %flip the buffer
		end
		ListenChar(0);
		if strcmpi(fixated,'breakfix')
			fprintf('===>>> BROKE INITIATE FIXATION Trial = %i\n', seq.thisRun);
			statusMessage(eL,'Subject Broke Initial Fixation!');
			edfMessage(eL,'MSG:BreakInitialFix');
			ana.nTotal = ana.nTotal + 1;
			ana.runningPerformance(ana.nTotal) = -1;
			ana.nInitiateBreak = ana.nInitiateBreak + 1;
			resetFixation(eL);
			stopRecording(eL);
			setOffline(eL);
			updatePlot(seq.thisRun);
			WaitSecs('YieldSecs',0.1);
			continue
		end
		
		%sM.verbose = false; eL.verbose = false; sM.verbosityLevel = 4; eL.verbosityLevel = 4; %force lots of log output
		
		%=========================Our actual stimulus drawing loop==========================
		edfMessage(eL,'END_FIX');
		statusMessage(eL,'Show Stimulus...');
		
		i=1;
		ii = 1;
		thisPupil = [];
		xPos = seq.outValues{seq.thisRun};
		yPos = circle1.yPosition;
		circle1.xPositionOut = xPos;
		circle2.xPositionOut = -xPos;
		
		%this allows the tracker to draw the stimulus positions
		stimulusPositions(1).x = xPos;
		stimulusPositions(1).y = yPos;
		stimulusPositions(1).size = circle1.size;
		stimulusPositions(1).selected = true;
		stimulusPositions(2).x = -xPos;
		stimulusPositions(2).y = yPos;
		stimulusPositions(2).size = circle2.size;
		stimulusPositions(2).selected = false;
		trackerDrawStimuli(eL,stimulusPositions);
		
		fprintf('===>>> Target Position=%s | Foil Position=%s\n',num2str(circle1.xPositionOut),num2str(circle2.xPositionOut));
		%edfMessage(eL,['MSG:modColor=' num2str(modColor)]);
		%edfMessage(eL,['MSG:variable=' num2str(seq.outIndex(seq.thisRun))]);
		%edfMessage(eL,['MSG:thisRun=' num2str(seq.thisRun)]);
		
		ana.trial(seq.thisRun).n = seq.thisRun;
		ana.trial(seq.thisRun).variable = seq.outIndex(seq.thisRun);
		ana.trial(seq.thisRun).pupil = [];
		ana.trial(seq.thisRun).frameN = [];
		
		if length(ana.delayToChoice) == 2
			delayToChoice = (rand * (ana.delayToChoice(2)-ana.delayToChoice(1))) + ana.delayToChoice(1);
		else
			delayToChoice = ana.delayToChoice;
		end
		fprintf('===>>> Delay to Choice is: %.2g\n',delayToChoice);
		
		tStart = GetSecs; vbl = tStart;if isempty(tL.vbl);tL.vbl(1) = tStart;tL.startTime = tStart; end

		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
		while GetSecs < tStart + delayToChoice
			
			circle2.draw(); %background circle draw first!
			circle1.draw();
			drawCross(sM,0.4,[1 1 1 1], ana.fixX, ana.fixY);
			finishDrawing(sM);
			
			[tL.vbl(tick),tL.show(tick),tL.flip(tick),tL.miss(tick)] = Screen('Flip',sM.win, vbl + halfisi);
			tL.stimTime(tick) = 0.5;
			tL.tick = tick;
			tick = tick + 1;
			i = i + 1;
			
			getSample(eL);
			thisPupil(ii) = eL.pupil;
			ii = ii + 1;
			if ~isFixated(eL)
				fixated = 'breakfix';
				break %break the while loop
			end
		end
		
		if ~strcmpi(fixated,'breakfix')
			resetFixation(eL);
			% X, Y, FixInitTime, FixTime, Radius, StrictFix
			updateFixationValues(eL, xPos, yPos,...
				ana.targetInitiation, ana.targetMaintain,...
				ana.targetDiameter, ana.strictFixation);
			fprintf('===>>> FIXX=%d | FIXY=%d\n',eL.fixationX,eL.fixationY);
			trackerDrawStimuli(eL,stimulusPositions,true);
			%trackerDrawExclusion(eL);
			trackerDrawFixation(eL); %draw fixation window on eyelink computer
			statusMessage(eL,'Saccade to Target...');
			tStart = GetSecs; vbl = tStart;
			while GetSecs < tStart + 2
				getSample(eL);
				circle2.draw(); %background circle draw first!
				circle1.draw();
				
				finishDrawing(sM);
				
				[tL.vbl(tick),tL.show(tick),tL.flip(tick),tL.miss(tick)] = Screen('Flip',sM.win, vbl + halfisi);
				tL.stimTime(tick) = 1;
				tL.tick = tick;
				tick = tick + 1;
				i = i + 1;
				
				fixated=testSearchHoldFixation(eL,'fix','breakfix');
				if strcmpi(fixated,'breakfix') || strcmpi(fixated,'fix')
					tFix = GetSecs; tReaction =  tFix - tStart;
					break %break the while loop
				elseif strcmp(fixated,'EXCLUDED!')
					tFix = GetSecs; 	tReaction =  tFix - tStart;
					break %break the while loop
				end
				thisPupil(ii) = eL.pupil;
				ii = ii + 1;
			end
		end
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
		%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
		
		sM.drawBackground();
		[tL.vbl(tick),tL.show(tick),tL.flip(tick),tL.miss(tick)]=Screen('Flip',sM.win);
		tL.stimTime(tick) = -1;
		tL.tick = tick;
		tick = tick + 1;
		tEnd = tL.vbl(end);
		
		trackerClearScreen(eL);
				
		ana.trial(seq.thisRun).pupil = thisPupil;
		ana.trial(seq.thisRun).totalFrames = ii-1;
		
		%=========================================check if we got fixation
		if strcmpi(fixated,'fix')
			lJ.timedTTL(2, ana.Rewardms)
			Beeper(1000,0.1,0.2);
			trackerDrawText(eL,'CORRECT!');
			fprintf('===>>> SUCCESS: Trial = %i (total:%.3g | reaction:%.3g)\n', seq.thisRun, tEnd-tStart, tReaction);
			ana.nSuccess = ana.nSuccess + 1;
			ana.nTotal = ana.nTotal + 1;
			ana.runningPerformance(ana.nTotal) = 1;
			ana.trial(seq.thisRun).success = true;
			ana.trial(seq.thisRun).reactionTime = tReaction;
			stopRecording(eL);
			edfMessage(eL,'TRIAL_RESULT 1');
			setOffline(eL);
			updatePlot(seq.thisRun);
			updateTask(seq,true); %updates our current run number
			iii = seq.thisRun;
			if ana.debug
				Screen('DrawText', sM.win, '===>>> CORRECT!!!', 0, 0);
				Screen('Flip',sM.win);
			end
			waitTime = ana.trialDelay;
		else
			if strcmpi(fixated,'breakfix')
				fprintf('===>>> BROKE FIXATION Trial = %i (total:%.3g | reaction:%.3g)\n', seq.thisRun, tEnd-tStart, tReaction);
				trackerDrawText(eL,'BREAK FIX!');
				edfMessage(eL,'TRIAL_RESULT -1');
				edfMessage(eL,'MSG:BreakFix');
			elseif strcmp(fixated,'EXCLUDED!')
				excludedN = excludedN + 1;
				fprintf('===>>> EXCLUSION ZONE Trial = %i > %i (total:%.3g | reaction:%.3g)\n', seq.thisRun, excludedN, tEnd-tStart, tReaction);
				trackerDrawText(eL,'BREAK FIX (EXCLUSION)!');
				edfMessage(eL,'TRIAL_RESULT -1');
				edfMessage(eL,'MSG:BreakFixExclusion');
			end
			stopRecording(eL);
			setOffline(eL);
			Beeper(180,1,2);
			ana.nFixBreak = ana.nFixBreak + 1;
			ana.nTotal = ana.nTotal + 1;
			ana.runningPerformance(ana.nTotal) = 0;
			updatePlot(seq.thisRun);
			if ana.debug
				Screen('DrawText', sM.win, '===>>> BREAK FIX!!!', 0, 0);
				Screen('Flip',sM.win);
			end
			waitTime = ana.punishDelay;
			if strcmp(fixated,'EXCLUDED!')
				waitTime = waitTime + 2;
			end
		end
		
		ListenChar(2);
		while GetSecs < tEnd + waitTime
			[keyIsDown, ~, keyCode] = KbCheck(-1);
			if keyIsDown == 1
				rchar = KbName(keyCode); if iscell(rchar);rchar=rchar{1};end
				switch lower(rchar)
					case {'c'}
						fprintf('===>>> Train recalibrate pressed!\n');
						stopRecording(eL);
						setOffline(eL);
						trackerSetup(eL);
						WaitSecs('YieldSecs',2);
					case {'d'}
						fprintf('===>>> Train drift correct pressed!\n');
						stopRecording(eL);
						driftCorrection(eL);
						WaitSecs('YieldSecs',2);
					case {'escape'}
						fprintf('===>>> Train escape pressed!!!\n');
						trackerClearScreen(eL);
						stopRecording(eL);
						setOffline(eL);
						breakLoop = true;
				end
			end
			WaitSecs('YieldSecs',sM.screenVals.ifi);
		end
		ListenChar(0);
		
	end % while ~breakLoop
	
	%===============================Clean up============================
	fprintf('===>>> Train Finished Trials: %i\n',seq.thisRun);
	Screen('DrawText', sM.win, '===>>> FINISHED!!!', 0, 0);
	Screen('Flip',sM.win);
	WaitSecs('YieldSecs', 2);
	close(sM); breakLoop = true;
	ListenChar(0);ShowCursor;Priority(0);
	close(lJ);
	
	if exist(ana.ResultDir,'dir') > 0
		cd(ana.ResultDir);
	end
	trackerClearScreen(eL);
	stopRecording(eL);
	setOffline(eL);
	close(eL);
	if ~isempty(ana.nameExp) && isempty(regexpi(ana.nameExp,'debug'))
		ana.plotAxis1 = [];
		ana.plotAxis2 = [];
		fprintf('==>> SAVE %s, to: %s\n', ana.nameExp, pwd);
		save([ana.nameExp '.mat'],'ana', 'seq', 'eL', 'sM', 'tL');
	end
	if IsWin
		tL.printRunLog;
	end
	clear ana seq eL sM tL
	
catch ME
	if exist('eL','var'); close(eL); end
	if exist('sM','var'); close(sM); end
	if exist('aM','var'); close(lJ); end
	ListenChar(0);ShowCursor;Priority(0);Screen('CloseAll');
	getReport(ME)
end

	function updatePlot(thisTrial)
		c = categorical({'BreakInit','BreakFix','Success'});
		bar(ana.plotAxis1,c,[ana.nInitiateBreak, ana.nFixBreak, ana.nSuccess]);
		
		p1 = 100 * (ana.nSuccess / (ana.nSuccess + ana.nInitiateBreak + ana.nFixBreak));
		p2 = 100 * (ana.nSuccess / (ana.nSuccess + ana.nFixBreak));
		if isinf(p1);p1 = 1; end; if isinf(p2);p2 = 1; end
		plotVals.t1(end+1) = thisTrial;
		plotVals.p1(end+1) = p1;
		plotVals.p2(end+1) = p2;
		plot(ana.plotAxis2,plotVals.t1,plotVals.p1,'go-');
		hold(ana.plotAxis2,'on');
		plot(ana.plotAxis2,plotVals.t1,plotVals.p2,'ko-','MarkerFaceColor',[1,0,0]);
		hold(ana.plotAxis2,'off');
		ylim(ana.plotAxis2,[0 100])
		
		if ana.nTotal >= 10
			recentList = ana.runningPerformance(end-9:end);
			bI = sum(recentList == -1);
			bF = sum(recentList == 0);
			cT = sum(recentList == 1);
			performance = 100 * ( cT / (cT+bF+bI) );
			plotVals.t2(end+1) = ana.nTotal;
			plotVals.p3(end+1) = performance;
			plot(ana.plotAxis3,plotVals.t2,plotVals.p3,'ko-','MarkerFaceColor',[1,0,0]);
			ylim(ana.plotAxis3,[0 100]);
		end
		drawnow
	end

end