function lineNr = getFunctionLineNr(functionName)
% Simple containers.Map to keep the line numbers to the functions used in
% files up to date to use them as a reference

    entries = {...
        % VehicleFollowingInit.m
        'discretiseContinuousSpace', 105;
    
        % LocalTrajectoryPlanner.m
        'planFrenetTrajectory', 72;
        'divideLaneChangingTrajectory', 95;
        'updateCurrentTrajectory', 110;
        'calculateTrajectoryToAdd', 129;
        'calculateLaneChangingTrajectory', 165;
        'calculateStraightTrajectory', 245;
        'getCurrentTrajectoryCartesian', 256;
        'getNextFrenetTrajectoryWaypoints', 264;
        'calculateTrajectoryError', 279;
        
        % StanleyPoseGenerator.m
        'getClosestPointOnTrajectory', 9;
        'getReferencePoseStanley', 41;
        
        % PlotDrivingScenario.m
        'plotVehicle', 35;
        'deletePreviousPlots', 95;
        'plotRoad', 111;
        'plotDiscreteSpace', 149;
        
        % ReachabilityAnalysis.m
        'calculateSteeringReachability', 59;
        };
    
    referenceFunctions = containers.Map(entries(:, 1)', [entries{:, 2}]);
        
    lineNr = referenceFunctions(functionName);
end