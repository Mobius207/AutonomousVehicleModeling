classdef LocalTrajectoryPlanner < ReachabilityAnalysis
% LocalTrajectoryPlanner Superclass for generating necessary inputs for 
% the lateral controllers.
    
    properties(Nontunable)
        vEgo_ref % Reference speed for ego vehicle [m/s]
        
        vOtherVehicles_ref % Reference speed for other vehicles [m/s]
        
        v_max % Maximum allowed velocity
        
        LaneWidth % Width of road lane [m]
        RoadTrajectory % Road trajectory according to MOBATSim map format
        
        partsTimeHorizon % Divide time horizon into partsTimeHorizon equal parts
        
        discreteCell_length % Length of dicrete cell in s-coordinate [m]
        spaceDiscretisationMatrix 
    end
    
    % Pre-computed constants
    properties(Access = protected)
        % Coefficents for lane changing trajectory
        a0
        a1
        a2
        a3
        a4
        a5
        
        laneChangeCmds % Possible commands for lane changing
        
        d_destination % Reference lateral destination (right or left lane)
        
        trajectoryReferenceLength % Number of points for trajectory generation
        
        fractionTimeHorizon % Fraction of time horizon when divided into partsTimeHorizon equal parts
        counter % Counter to stop at correct simulation time
        predictedTrajectory % Store future trajectory predictions for replanning
        
        laneChangingTrajectoryFrenet % Planned trajectory for lane changing in Frenet coordinates [s, d, s_curve, time] (s_curve = coordinate along the lane changing curve)
        laneChangingTrajectoryCartesian % Planned trajectory for lane changing in Cartesian coordinates [x, y, orientation, time]
        futurePosition % Preedicted future position according to time horizon

        timeStartLaneChange % Time when starting lane changing maneuver
        
        curvature_max % Maximum allowed curvature
        
        a_lateral_max % Maximum allowed lateral acceleration
    end
    
    methods
        function obj = LocalTrajectoryPlanner(varargin)
            %WAYPOINTGENERATOR Construct an instance of this class
            %   Detailed explanation goes here
            setProperties(obj,nargin,varargin{:});
        end
    end
    
    methods(Access = protected)
        function setupImpl(obj)
            % Perform one-time calculations, such as computing constants
            setupImpl@ReachabilityAnalysis(obj) 

            obj.laneChangeCmds = ...
                containers.Map({'CmdIdle', 'CmdStartToLeftLane', 'CmdStartToRightLane'}, [0, 1, -1]);
            
            obj.d_destination = 0; % Start on right lane
            
            % +1 because planned trajectory contains current waypoint at current time
            obj.trajectoryReferenceLength = obj.timeHorizon/obj.Ts + 1; 
            
            obj.fractionTimeHorizon = obj.timeHorizon/obj.partsTimeHorizon;
            obj.counter = 0;
            obj.predictedTrajectory = [];
            
            obj.curvature_max = tan(obj.steerAngle_max)/obj.wheelBase;
            
            obj.a_lateral_max = 30; % Placeholder
        end
        
        function planTrajectory(obj, changeLaneCmd, replan, s, d, a, v, poseOtherVehicles, speedsOtherVehicles)
        % Plan trajectory for the next obj.timeHorizon seconds in Frenet and Cartesian coordinates
            
            if changeLaneCmd 
                obj.timeStartLaneChange = get_param('VehicleFollowing', 'SimulationTime');
                obj.calculateLaneChangingManeuver(changeLaneCmd, s, d, 0, 0, v, poseOtherVehicles, speedsOtherVehicles); 
            end
            
            if replan
                % TODO: Add
            end
            
            % TODO: Do at every simulation time step?
            obj.predictFuturePosition(s, v, a);
        end
        
        function calculateLaneChangingManeuver(obj, changeLaneCmd, s, d, d_dot, d_ddot, v, poseOtherVehicles, speedsOtherVehicles)
        % Calculate lane changing maneuver either to the left or right lane
            
            if changeLaneCmd == obj.laneChangeCmds('CmdStartToLeftLane')
                d_goal = obj.LaneWidth;
            elseif changeLaneCmd == obj.laneChangeCmds('CmdStartToRightLane')
                d_goal = 0;
            end
            
            time_trajectory = get_param('VehicleFollowing', 'SimulationTime') + (0:obj.Ts:obj.timeHorizon); 
            
            [occupiedCells_otherVehiclesFront, occupiedCells_otherVehiclesRear] = obj.getOccupiedCellsOtherVehicles(s, poseOtherVehicles, speedsOtherVehicles, time_trajectory);
  
            cost_min = inf;
            for durManeuver = 1:0.2:obj.timeHorizon
                [trajectoryFrenet, trajectoryCartesian, cost, isFeasibleTrajectory] = obj.calculateLaneChangingTrajectory(s, d, d_dot, d_ddot, d_goal, durManeuver, v);
                
                % Feasibility Check
                if isFeasibleTrajectory
                    % TODO: Take vehicles' dimensions into account
                    occupiedCells_trajectory = Continuous2Discrete(obj.spaceDiscretisationMatrix, trajectoryFrenet(:, 1), trajectoryFrenet(:, 2), trajectoryFrenet(:, 3));

                    % Safety check
                    isSafeTrajectoryToVehiclesFront = obj.checkTrajectoryIntersection(occupiedCells_trajectory, occupiedCells_otherVehiclesFront, 'front');
                    isSafeTrajectoryToVehiclesRear = obj.checkTrajectoryIntersection(occupiedCells_trajectory, occupiedCells_otherVehiclesRear, 'rear');

                    if (isSafeTrajectoryToVehiclesFront && isSafeTrajectoryToVehiclesRear)
                        
                        % Cost check
                        if cost < cost_min
                            obj.laneChangingTrajectoryFrenet = trajectoryFrenet;
                            obj.laneChangingTrajectoryCartesian = trajectoryCartesian;
                            
                            cost_min = cost;
                        end
                    end   
                end
            end
            
            if ~isempty(obj.laneChangingTrajectoryCartesian)
                obj.d_destination = d_goal;
                plot(obj.laneChangingTrajectoryCartesian(:, 1), obj.laneChangingTrajectoryCartesian(:, 2), 'Color', 'green');
                assignin('base', 'isAcceptedTrajectory', true);
            else
               assignin('base', 'isAcceptedTrajectory', false);
            end
        end
        
        function [occupiedCells_otherVehiclesFront, occupiedCells_otherVehiclesRear] = getOccupiedCellsOtherVehicles(obj, sEgo, poseOtherVehicles, speedsOtherVehicles, time_trajectory)
        % Get occupied cells for other vehicles ahead and behind the ego vehicle
            
            % TODO: Maybe only necessary for surrounding vehicles            
            occupiedCells_otherVehiclesFront = zeros(size(poseOtherVehicles, 2)*4*obj.trajectoryReferenceLength, 4); % Preallocate: At most 4 cells can be occupied for one (s, d) tuple for each vehicle
            id_front = 1;
            occupiedCells_otherVehiclesRear = zeros(size(poseOtherVehicles, 2)*4*obj.trajectoryReferenceLength, 4);
            id_rear = 1;
            for id_otherVehicle = 1:size(poseOtherVehicles, 2)
                [s_otherVehicle_current, d_otherVehicle] = Cartesian2Frenet(obj.RoadTrajectory, [poseOtherVehicles(1, id_otherVehicle), poseOtherVehicles(2, id_otherVehicle)]);
                
                if s_otherVehicle_current > sEgo % Other vehicle ahead of ego vehcile
                    acceleration_worstCase = obj.minimumAcceleration; % Worst case: Full break
                else % Other vehicle behind ego vehicle
                    acceleration_worstCase = obj.maximumAcceleration; % Worst case: Maximum acceleration
                end
                    
                [s_otherVehicle_trajectory, ~] = obj.calculateLongitudinalTrajectory(s_otherVehicle_current, speedsOtherVehicles(id_otherVehicle), obj.v_max, acceleration_worstCase, obj.trajectoryReferenceLength);
                d_otherVehicle_trajectory = d_otherVehicle*ones(1, size(s_otherVehicle_trajectory, 2));
                
                occupiedCells_otherVehicle = Continuous2Discrete(obj.spaceDiscretisationMatrix, s_otherVehicle_trajectory, d_otherVehicle_trajectory, time_trajectory);
                
                if s_otherVehicle_current > sEgo % Ahead
                    [occupiedCells_otherVehiclesFront, id_front] = obj.addCells(id_front, occupiedCells_otherVehiclesFront, occupiedCells_otherVehicle);
                else % Behind
                    [occupiedCells_otherVehiclesRear, id_rear] = obj.addCells(id_rear, occupiedCells_otherVehiclesRear, occupiedCells_otherVehicle);
                end
            end
            
            occupiedCells_otherVehiclesFront = occupiedCells_otherVehiclesFront(1:id_front-1, :);
            occupiedCells_otherVehiclesRear = occupiedCells_otherVehiclesRear(1:id_rear-1, :);
        end
        
        function [trajectoryFrenet, trajectoryCartesian, cost, isFeasibleTrajectory] = calculateLaneChangingTrajectory(obj, s_current, d_currnet, d_dot_current, d_ddot_current, d_destination, durationManeuver, v_current)
        % Calculate minimum jerk trajectory for lane changing maneuver
            
            % Initial conditions
            t_i = 0; % Start at 0 (relative time frame)
                    
            d_i =         [1  t_i   t_i^2   t_i^3    t_i^4      t_i^5]; % d_initial = d_current 
            d_dot_i =     [0  1     2*t_i   3*t_i^2  4*t_i^3    5*t_i^4]; %  0
            d_ddot_i =    [0  0     2       6*t_i    12*t_i^2   20*t_i^3]; %  0

            % Final conditions
            t_f = durationManeuver; % time to finish maneuver

            d_f =         [1  t_f   t_f^2   t_f^3    t_f^4      t_f^5]; % d_destination
            d_dot_f =     [0  1     2*t_f   3*t_f^2  4*t_f^3    5*t_f^4]; % 0
            d_ddot_f =    [0  0     2       6*t_f    12*t_f^2   20*t_f^3]; % 0

            A = [d_i; d_dot_i; d_ddot_i; d_f; d_dot_f; d_ddot_f];

            B = [d_currnet; d_dot_current; d_ddot_current; d_destination; 0; 0];

            X = linsolve(A,B);

            obj.a0 = X(1);
            obj.a1 = X(2); 
            obj.a2 = X(3);
            obj.a3 = X(4);
            obj.a4 = X(5);
            obj.a5 = X(6);
            
            % Calculate trajectory for whole maneuver
            t_discrete = 0:obj.Ts:durationManeuver; 
            
            d_trajectory = obj.a0 + obj.a1*t_discrete + obj.a2*t_discrete.^2 + obj.a3*t_discrete.^3 + obj.a4*t_discrete.^4 + obj.a5*t_discrete.^5;
            d_dot_trajectory = obj.a1 + 2*obj.a2*t_discrete + 3*obj.a3*t_discrete.^2 + 4*obj.a4*t_discrete.^3 + 5*obj.a5*t_discrete.^4;
            d_ddot_trajectory = 2*obj.a2 + 6*obj.a3*t_discrete + 12*obj.a4*t_discrete.^2 + 20*obj.a5*t_discrete.^3;
            d_dddot_trajectory = 6*obj.a3 + 24*obj.a4*t_discrete + 60*obj.a5*t_discrete.^2;
            
            % s_curve coordinate going along the lane changing curve
            % Calculate profile according to FreeDrive 
            [s_curve_trajectory, v_trajectory] = obj.calculateLongitudinalTrajectory(s_current, v_current, obj.vEgo_ref, obj.maximumAcceleration, length(t_discrete));
            
            s_dot_trajectory = sqrt(v_trajectory.^2 - d_dot_trajectory.^2); 
            
            % Future prediction s along the road
            s_trajectory = zeros(1, length(t_discrete)); % TODO: Check: s along the road, what if acceleration?
            s = s_current;
            for k = 1:length(t_discrete) % Numerical integration
                s_trajectory(k) = s;
                s = s + s_dot_trajectory(k)*obj.Ts;
            end
            
            if durationManeuver < obj.timeHorizon % Need to add straight trajectory
                t_straight = durationManeuver+obj.Ts:obj.Ts:obj.timeHorizon; 
                
                % Predict one step for durationManeuver+obj.Ts
                [s_0, v_0] = obj.predictLongitudinalFutureState(s_trajectory(end), v_trajectory(end), obj.vEgo_ref, obj.maximumAcceleration, 0);
                [s_trajectory_straight, v_trajectory_straight] = obj.calculateLongitudinalTrajectory(s_0, v_0, obj.vEgo_ref, obj.maximumAcceleration, length(t_straight));
                
                s_trajectory = [s_trajectory, s_trajectory_straight];
                s_curve_trajectory = [s_curve_trajectory, s_trajectory_straight]; % For straight trajectory s_curve = s
                v_trajectory = [v_trajectory, v_trajectory_straight];
                s_dot_trajectory = [s_dot_trajectory, v_trajectory_straight]; % For straight trajectory s_dot = v
                
                d_trajectory = [d_trajectory, d_destination*ones(1, length(t_straight))];
                d_dot_trajectory = [d_dot_trajectory, zeros(1, length(t_straight))];
                d_ddot_trajectory = [d_ddot_trajectory, zeros(1, length(t_straight))];
                d_dddot_trajectory = [d_dddot_trajectory, zeros(1, length(t_straight))];
                t_discrete = [t_discrete, t_straight];
            end
            
            % Cost function according to jerk
            cost = 0.5*sum(d_dddot_trajectory.^2);
            
            [laneChangingPositionCartesian, roadOrientation] = Frenet2Cartesian(s_trajectory', d_trajectory', obj.RoadTrajectory);
            orientation = atan2(d_dot_trajectory, s_dot_trajectory)' + roadOrientation;
            
            time = get_param('VehicleFollowing', 'SimulationTime') + t_discrete;
            
            trajectoryFrenet = [s_trajectory', d_trajectory', s_curve_trajectory', time'];
            trajectoryCartesian = [laneChangingPositionCartesian, orientation, time'];
            
            isFeasibleTrajectory = obj.isFeasibleTrajectory(trajectoryCartesian, v_trajectory);
        end 
        
        function [s_trajectory, v_trajectory] = calculateLongitudinalTrajectory(obj, s_0, v_0, v_max, acceleration, trajectoryLength)
        % Calculate longitudinal trajectory according to the longitudinal
        % reachability analysis using each time step
            
            v_trajectory = zeros(1, trajectoryLength);
            s_trajectory = zeros(1, trajectoryLength);
            
            % Future prediction s, v
            s = s_0; 
            v = v_0;
            for k = 1:trajectoryLength % Numerical integration
                v_trajectory(k) = v;
                s_trajectory(k) = s;
                [s, v] = obj.predictLongitudinalFutureState(s, v, v_max, acceleration, 0); % Prediction just for next time step
            end
        end
        
        function isFeasible = isFeasibleTrajectory(obj, trajectory, velocity_trajectory)
        % Check if trajectory is feasible accoording to lateral acceleration and trajectory curviture
            
            x = trajectory(:, 1);
            y = trajectory(:, 2);
            orientation = trajectory(:, 3);
            
            delta_orientation = diff(orientation);
            delta_position = sqrt((diff(x)).^2 + (diff(y)).^2);
            
            curvature = delta_orientation./delta_position;
            a_centrifugal = velocity_trajectory(1:end-1)'.^2.*curvature; % Alternative: Limit by using d_ddot
            
            isFeasibleCurvature = all(abs(curvature) < obj.curvature_max);
            isFeasibleCentrifugalAcceleration = all(abs(a_centrifugal) < obj.a_lateral_max); % Placeholder for a_lateral_max
            
            isFeasible = isFeasibleCurvature && isFeasibleCentrifugalAcceleration;
        end
        
        function predictFuturePosition(obj, s_current, v_current, a_current)
        % Predict future position in a specified time horizon
            
            % Future prediction until time horizon for constant acceleration
            % TODO: Limit by reference velocity or maximum allowed velocity?
            [s_future, ~] = obj.predictLongitudinalFutureState(s_current, v_current, obj.vEgo_ref, a_current, obj.k_timeHorizon); 
        
            if ~isempty(obj.laneChangingTrajectoryFrenet) && ~isempty(obj.laneChangingTrajectoryCartesian) % For lane changing
                distance_future = s_future - s_current;
                
                % Get future s_curve value
                s_trajectory = obj.laneChangingTrajectoryFrenet(:, 1);
                ID_currentWP = sum(s_current >= s_trajectory);
                
                s_curve_future = obj.laneChangingTrajectoryFrenet(ID_currentWP, 3) + distance_future;
                
                % Get future s and d value from lane changing trajectory using future s_curve value 
                s_curve_trajectory = obj.laneChangingTrajectoryFrenet(:, 3);
                ID_futureWP = sum(s_curve_future >= s_curve_trajectory);
                
                if ID_futureWP >= size(obj.laneChangingTrajectoryFrenet, 1)
                    % Simplification: Predict position on destination lane not considering lane changing trajectory anymore
                    d_future = obj.d_destination; 
                else
                    s_future = obj.laneChangingTrajectoryFrenet(ID_futureWP, 1);
                    d_future = obj.laneChangingTrajectoryFrenet(ID_futureWP, 2);
                end
            else % For following the road
                d_future = obj.d_destination;
            end
            
            futureTime = get_param('VehicleFollowing', 'SimulationTime') + obj.timeHorizon;
            [futurePos, ~] = Frenet2Cartesian(s_future, d_future, obj.RoadTrajectory);
            obj.futurePosition = [futurePos, futureTime]; % [x, y, time]
        end
        
        function [s_ref, d_ref] = getNextFrenetTrajectoryWaypoints(obj, s, v, numberWPs)
        % Get the next waypoint(s) for current trajectory according to current s in Frenet coordinates
            
            if ~isempty(obj.laneChangingTrajectoryFrenet)
                s_trajectory =  obj.laneChangingTrajectoryFrenet(:, 1); 
                ID_nextWP = sum(s >= s_trajectory) + 1;
                
                if ID_nextWP > size(obj.laneChangingTrajectoryFrenet, 1) % No more lane changing points left
                    obj.laneChangingTrajectoryFrenet = [];
                    [s_ref, d_ref] = obj.getNextRoadTrajectoryWaypoints(s, v, numberWPs);
                    return
                end
                
                % Add points from lane changing trajectory
                numberResidualLaneChangingPoints = size(obj.laneChangingTrajectoryFrenet, 1) - (ID_nextWP-1);
                numberPointsFromLaneChanging = min(numberResidualLaneChangingPoints, numberWPs);
                s_ref = obj.laneChangingTrajectoryFrenet(ID_nextWP:ID_nextWP+(numberPointsFromLaneChanging-1), 1);
                d_ref = obj.laneChangingTrajectoryFrenet(ID_nextWP:ID_nextWP+(numberPointsFromLaneChanging-1), 2);
                
                % Add points from road trajectory if necessary
                numberPointsFromRoadTrajectory = numberWPs - numberPointsFromLaneChanging;
                if numberPointsFromRoadTrajectory > 0
                    [s_add, d_add] = obj.getNextRoadTrajectoryWaypoints(s_ref(end), v, numberPointsFromRoadTrajectory);
                    s_ref = [s_ref; s_add];
                    d_ref = [d_ref; d_add];
                end
            else
                [s_ref, d_ref] = obj.getNextRoadTrajectoryWaypoints(s, v, numberWPs);
            end
        end
        
        function [s_ref, d_ref] = getNextRoadTrajectoryWaypoints(obj, s, v, numberPoints)
        % Get next waypoints for staying on the same lane and following the road trajectory
            
            s_ref = s + linspace(v*obj.Ts, numberPoints*v*obj.Ts, numberPoints)'; % Linear spacing according to current velocity
            d_ref = obj.d_destination*ones(numberPoints, 1);
        end
        
        function replan = calculateTrajectoryError(obj, s, d)
        % Track error between predicted trajectory and actual trajectory every fractionTimeHorizon seconds
        % If the error exceeds threshold, replan maneuver
           
            replan = false;
            if get_param('VehicleFollowing', 'SimulationTime') > obj.counter*obj.fractionTimeHorizon
                if ~isempty(obj.predictedTrajectory)
                    error_s_d = obj.predictedTrajectory(1:2) - [s, d];
                    % TODO: Find threshold values that make sense and calculate new acceleration command
                    replan = (abs(error_s_d(1)) > 1) || (abs(error_s_d(2)) > 0.1);
                end 

%                 obj.setTrajectoryPrediction(); % TODO: Check again later, only working for lane changing trajectory yet
                obj.counter = obj.counter + 1;
            end
        end
        
        function setTrajectoryPrediction(obj)
        % Set prediction for the future position according to the planned trajectory in the next fractionTimeHorizon seconds
            
            timeToCheck = (obj.counter+1)*obj.fractionTimeHorizon;
            trajectoryTime = obj.laneChangingTrajectoryFrenet(:, end);
            
            ID_nextPrediction = sum(timeToCheck >= trajectoryTime); % ID for next predicted time
            obj.predictedTrajectory = obj.laneChangingTrajectoryFrenet(ID_nextPrediction, :); 
        end
    end
    
    methods(Static)
        function [cells_total, id_next] = addCells(id, cells_total, cells_toAdd)
        % Add new cells to list
            
            id_next = id + size(cells_toAdd, 1);
            
            cells_total(id:id_next-1, :) = cells_toAdd;
        end
        
        function isSafeTrajectory = checkTrajectoryIntersection(trajectory_ref, trajectory_other, relativePosition_other)
        % Check whether discrete reference trajectory is safe by calculating the
        % intersection between discrete reference trajectory and other discrete trajectories
        
            if ~(strcmp(relativePosition_other, 'front') || strcmp(relativePosition_other, 'rear'))
                error('Invalid relative position of other trajectories. Specify relative position as ''front'' or ''rear''.');
            end
        
            isSafeTrajectory = true;
            [commonCells, id_intersect_ref, id_intersect_other] = intersect(trajectory_ref(:, 1:2), trajectory_other(:, 1:2), 'rows');
            if ~isempty(commonCells)
                if strcmp(relativePosition_other, 'front')
                    isSafeTrajectory = all(trajectory_ref(id_intersect_ref, 3) > trajectory_other(id_intersect_other, 4));
                else 
                    isSafeTrajectory = all(trajectory_ref(id_intersect_ref, 4) < trajectory_other(id_intersect_other, 3));
                end
            end
        end
    end
end

