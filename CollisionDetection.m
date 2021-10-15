classdef CollisionDetection < matlab.System
    % Check for vehicle collisions

    % Public, tunable properties
    properties

    end
    
    properties(Nontunable)
        rEgo = evalin('base', 'R2'); % Radius around ego vehicle rectangle representation
        rLead = evalin('base', 'R1'); % Radius around lead vehicle rectangle representation
        dimEgo = evalin('base', 'V2_dim'); % Dimensions (length, width) ego vehicle
        dimLead = evalin('base', 'V1_dim') ; % Dimensions (length, width) lead vehicle
    end
    
    properties(DiscreteState)

    end

    % Pre-computed constants
    properties(Access = private)

    end

    methods(Access = protected)
        function setupImpl(obj)
            % Perform one-time calculations, such as computing constants
        end

        function collisionDetected = stepImpl(obj, poseLead, poseEgo)
            % Check whether a collision between two vehicles is detected
            
            collisionDetected = false; 
            
            % Check if vehicles are close enough: d_euclidian <= (rEgo + rLead)
            d_euclidian = obj.calculateEuclidianDistance(poseEgo(1), poseEgo(2), poseLead(1), poseLead(2));
            if d_euclidian <= obj.rEgo + obj.rLead
                HitboxEgo = obj.getHitbox(poseEgo, obj.dimEgo);
                HitboxLead = obj.getHitbox(poseLead, obj.dimLead);
                collisionDetected = obj.checkIntersection(HitboxLead, HitboxEgo);
            end
        end
        
        function d_euclidian = calculateEuclidianDistance(~, x1, y1, x2, y2)
            % Calculate Euclidian distance between two points P1(x1, y1)
            % and P2(x2, y2)
            d_euclidian = sqrt((x2 - x1)^2 + (y2 - y1)^2);
        end
        
        function Hitbox = getHitbox(~, pose, dim)
            % Get vehicle hitbox (representation as rectangle)
            
            % Vehicle pose
            x = pose(1);
            y = pose(2);
            yaw = pose(3);

            centerP = [x; y];

            V_Length = dim(1);
            V_Width = dim(2);

            % Vehicle as rectangle
            p1 = [V_Length/2; V_Width/2];
            p2 = [V_Length/2; -V_Width/2];
            p3 = [-V_Length/2; -V_Width/2];
            p4 = [-V_Length/2; V_Width/2];

            % Rotation of rectangle points
            Rmatrix = [cos(yaw) -sin(yaw);
                       sin(yaw)  cos(yaw)];

            p1r = centerP + Rmatrix*p1;
            p2r = centerP + Rmatrix*p2;
            p3r = centerP + Rmatrix*p3;
            p4r = centerP + Rmatrix*p4;

            % Connect points to rectangle
            Hitbox = [p1r p2r p3r p4r];
        end
        
        %% FROM MOBATSim
        function CollisionFlag = checkIntersection(~, BoxA, BoxB)
            % Check if there is an intersection between two rectangle hitboxes
            CornersAx = transpose(BoxA(1,:));
            CornersAy = transpose(BoxA(2,:));
            CornersBx = transpose(BoxB(1,:));
            CornersBy = transpose(BoxB(2,:));
            
            in = inpolygon(CornersAx,CornersAy,CornersBx,CornersBy);
            
            if max(in) > 0
                CollisionFlag = true;
                return;
            else
                in = inpolygon(CornersBx,CornersBy,CornersAx,CornersAy);
                if max(in) > 0
                    CollisionFlag = true;
                    % To plot the collision scene
                    %plot(CornersAx,CornersAy,CornersBx,CornersBy)
                    return;
                else
                    CollisionFlag = false;
                    return;
                end 
            end
        end
        
        %%
        function resetImpl(obj)
            % Initialize / reset discrete-state properties
        end
        
        function out = getOutputSizeImpl(obj)
            % Return size for each output port
            out = [1 1];

            % Example: inherit size from first input port
            % out = propagatedInputSize(obj,1);
        end

        function out = getOutputDataTypeImpl(obj)
            % Return data type for each output port
            out = "boolean";

            % Example: inherit data type from first input port
            % out = propagatedInputDataType(obj,1);
        end

        function out = isOutputComplexImpl(obj)
            % Return true for each output port with complex data
            out = false;

            % Example: inherit complexity from first input port
            % out = propagatedInputComplexity(obj,1);
        end

        function out = isOutputFixedSizeImpl(obj)
            % Return true for each output port with fixed size
            out = true;

            % Example: inherit fixed-size status from first input port
            % out = propagatedInputFixedSize(obj,1);
        end
    end
end
