class MoosasVent
    Ver='0.6.4'
    require 'json'
    def self.running?
        @running == true
    end

    def self.analysis
        return false if running? || MMR.transform_running? || (defined?(MoosasDaylight) && MoosasDaylight.running?)
        if $language == 'Chinese'
            input = UI.inputbox(["风速：", "风向：", "计算热压通风"], ["3.0", "225", "No"],
                                ["", "", "No|Yes"], "请输入室外风况条件！")
        else
            input = UI.inputbox(["Wind Speed", "Wind Direction", "Simulate Thermal Ventilation"],
                                ["3.0", "225", "No"], ["", "", "No|Yes"], "Please Enter The Wind Condition")
        end
        return false unless input
        speed = Float(input[0])
        direction = (270.0 - Float(input[1])) % 360.0
        thermal = input[2] == 'Yes'
        temperatures = [20.0, 20.0]
        if thermal
            prompts = $language == 'Chinese' ? ["模拟室外温度", "模拟室内温度"] : ["Outdoor Temperature", "Indoor Temperature"]
            temperatures = UI.inputbox(prompts, ["20", "27"], "Temperature Settings")
            return false unless temperatures
        end
        call_vent(speed, direction, Float(temperatures[0]), Float(temperatures[1]), 0.22, thermal)
    rescue StandardError => e
        p "Ventilation input error: #{e.message}"
        UI.messagebox(e.message)
        false
    end

    # Direction is already converted from the UI convention; all physics runs in Python.
    def self.call_vent(wind_speed, wind_direction, out_temp, in_temp, alpha, thermal, &on_complete)
        return false if defined?(MoosasModelPage) && MoosasModelPage.saving?
        return false if running? || MMR.transform_running? || (defined?(MoosasDaylight) && MoosasDaylight.running?)
        values = [wind_speed, wind_direction, out_temp, in_temp, alpha].map { |v| Float(v) }
        raise "Invalid ventilation boundary conditions" unless values.all?(&:finite?) && values[0] >= 0
        @running = true
        @last_error = nil
        source_model = Sketchup.active_model
        started = MMR.update_model do |ready|
            if ready
                begin
                    submit_job(values, thermal, source_model, &on_complete)
                rescue StandardError => e
                    finish_job(false, e.message, &on_complete)
                end
            else
                finish_job(false, "Model recognition failed", &on_complete)
            end
        end
        @running = false unless started
        started
    rescue StandardError
        @running = false
        raise
    end

    def self.finish_job(success, error = nil, &on_complete)
        @running = false
        @last_error = error
        p "Ventilation failed: #{error}" unless success
        Sketchup.status_text = success ? 'Ventilation complete' : "Ventilation failed: #{error}"
        on_complete.call(success) if on_complete
    end

    def self.geometry_signature
        MMR.geometries.map do |g|
            [g.uid, g.face.valid? ? g.face.vertices.map { |v| v.position.to_a } : nil, g.transformation.to_a]
        end
    end

    def self.submit_job(values, thermal, source_model, &on_complete)
        require 'tmpdir'
        require 'fileutils'
        require 'securerandom'
        files = MMR.rdf_files
        raise "No current RDF files available" if files.empty?
        job_id = SecureRandom.uuid
        parent = File.join(MPath::DATA, 'vent', 'jobs')
        FileUtils.mkdir_p(parent)
        workspace = Dir.mktmpdir('vent-', parent)
        @last_workspace = workspace
        # Freeze inputs so a later Remodel cannot overwrite a running job's RDF.
        files = files.each_with_index.map do |file, index|
            target = File.join(workspace, "input_#{index}.ttl")
            FileUtils.cp(file, target)
            target
        end
        radians = values[1] * Math::PI / 180.0
        request = {
            'schema_version' => 1, 'job_id' => job_id, 'rdf_files' => files,
            'boundary_conditions' => {
                'wind_direction_vector' => [Math.sin(radians), Math.cos(radians), 0.0],
                'wind_speed_m_s' => values[0], 'outdoor_temperature_c' => values[2],
                'indoor_temperature_c' => values[3], 'alpha' => values[4], 'thermal' => !!thermal
            }
        }
        request_path = File.join(workspace, 'request.json')
        File.write(request_path, JSON.pretty_generate(request), :encoding => 'UTF-8')
        geometry_snapshot = MMR.geometries.dup
        signature = geometry_signature
        code = ["from skp.scripts.airflow_job import execute", "execute(#{request_path.to_json})"]
        started = MoosasUtils.exec_python_async('ventilation.py', code) do |success|
            error = nil
            begin
                result_path = File.join(workspace, 'result.json')
                raise "Python exited without result; see job logs" unless File.file?(result_path)
                result = JSON.parse(File.read(result_path, :encoding => 'UTF-8'))
                raise(result['error'] || "Python ventilation failed") unless success && result['success']
                raise "Mismatched ventilation result" unless result['schema_version'] == 1 && result['job_id'] == job_id
                raise "Model changed during simulation; result retained without drawing" unless Sketchup.active_model == source_model && MMR.geometries == geometry_snapshot && geometry_signature == signature
                visualize_result(result)
                @last_result = result
                p "Building outdoor-air ACH: #{calculate_ach(result).round(3)} h^-1"
                result.fetch('warnings', []).each { |warning| p warning }
            rescue StandardError => e
                success = false
                p e.backtrace.join("\n")
                error = "#{e.message} (#{workspace})"
            end
            finish_job(success, error, &on_complete)
        end
        raise "Could not launch ventilation Python process" unless started
        true
    end

    def self.calculate_ach(result)
        zones = result.fetch('networks').flat_map { |network| network.fetch('zones') }
        volume = zones.sum { |zone| Float(zone.fetch('volume_m3')) }
        raise "Invalid total zone volume" unless volume > 0
        zones.sum { |zone| Float(zone.fetch('outdoor_inflow_m3_h')) } / volume
    end

    def self.visualize_result(result)
        model = Sketchup.active_model
        lookup = MMR.geometries.each_with_object({}) { |geometry, map| map[geometry.uid.to_s] = geometry }
        model.start_operation('Ventilation results', true)
        begin
            previous = model.entities.grep(Sketchup::Group).select { |g| g.get_attribute('MoosasVent', 'result') }
            group = model.entities.add_group
            group.name = 'Moosas Ventilation'
            group.set_attribute('MoosasVent', 'result', true)
            group.set_attribute('MoosasVent', 'building_ach', calculate_ach(result))
            result.fetch('networks').each do |network|
                network.fetch('zones').each do |zone|
                    ach = Float(zone['outdoor_inflow_m3_h']) / Float(zone['volume_m3'])
                    group.set_attribute('MoosasVent', "ach_#{zone['uid']}", ach)
                end
                network.fetch('paths').each do |path|
                    geometry = lookup[path['uid'].to_s]
                    unless geometry
                        p "No SketchUp geometry for airflow path #{path['uid']}" unless path['kind'] == 'leakage'
                        next
                    end
                    [[1, 'forward_velocity_m_s'], [-1, 'reverse_velocity_m_s']].each do |sign, key|
                        velocity = Float(path.fetch(key))
                        next unless velocity > 1.0e-8
                        direction = Geom::Vector3d.new(path.fetch('direction'))
                        next if direction.length.to_f < 1.0e-8
                        direction.reverse! if sign < 0
                        center = draw_arrow(geometry, velocity, direction)[0]
                        direction.length = [[velocity * 3.0, 0.15].max, 10.0].min / 0.0254
                        # Offset opposing streams so two-way flow remains visible.
                        side = direction.cross(Geom::Vector3d.new(0, 0, 1))
                        side = direction.cross(Geom::Vector3d.new(1, 0, 0)) if side.length.to_f < 1.0e-8
                        side.length = 0.08 / 0.0254
                        center = center.offset(side)
                        tip = center.offset(direction)
                        back = direction.reverse
                        back.length = direction.length * 0.25
                        side.length = back.length * 0.4
                        arrow = group.entities.add_group
                        arrow.set_attribute('MoosasVent', 'uid', path['uid'])
                        arrow.set_attribute('MoosasVent', 'velocity_m_s', velocity)
                        arrow.entities.add_line(center, tip)
                        arrow.entities.add_line(tip, tip.offset(back).offset(side))
                        arrow.entities.add_line(tip, tip.offset(back).offset(side.reverse))
                        arrow.entities.add_text("#{velocity.round(3)} m/s", tip)
                    end
                end
            end
            group.entities.add_text("Outdoor-air ACH: #{calculate_ach(result).round(3)} h^-1", model.bounds.center)
            previous.each(&:erase!)
            model.commit_operation
        rescue Exception
            model.abort_operation
            raise
        end
        group
    end

    def self.run_vent_legacy(model, wind_speed, wind_direction,out_temp,in_temp, alpha,thermal)
    # Function:
    # Executes a legacy ventilation simulation using empirical wind pressure models and external tools (XGBoost, CONTAM).
    # This method calculates airflow through building openings based on wind speed, direction, thermal conditions,
    # and geometric properties. It interfaces with Python-based XGBoost for wind pressure prediction and runs
    # airflow network simulations via afn.exe. Optionally performs thermal iteration and visualizes results.
    # 
    # Parameters:
    # model : OpenStudio::Model
    # The building energy model containing spaces, surfaces, and glazing definitions.
    # wind_speed : Float
    # Wind speed in meters per second (m/s) used to calculate dynamic pressure.
    # wind_direction : Float
    # Wind direction in degrees relative to the building's orientation (0-360).
    # out_temp : Float
    # Outdoor air temperature in degrees Celsius for thermal calculations.
    # in_temp : Float
    # Indoor air temperature in degrees Celsius for thermal buoyancy and heating calculations.
    # alpha : Float
    # Empirical exponent for height-dependent wind pressure adjustment (typically 0.2–0.5).
    # thermal : Boolean
    # Flag indicating whether to include thermal effects (buoyancy, internal heat gains) in the simulation.
    # 
    # Returns:
    # Float
    # Air changes per hour (ACH), calculated as total volumetric airflow divided by total building volume,
    # rounded to two decimal places. Represents the overall ventilation rate of the building.
        zones, paths, paths_inner, bdh, params, heights, rv = [], [], {}, calculate_bdh(model), "", [], 0
        simulation_spaces = model.simulation_spaces
        for i in 0..simulation_spaces.length - 1 do
            s = simulation_spaces[i]
            vertices_=[]
            s.floor.each{|floor| floor.face.vertices.each{|ver| vertices_.push(ver)}}
            z = (s.area_m * s.height_m).round(2).to_s  + "," + self.calculate_midpoint(vertices_)
            vertices_.each do |v|
                x = (v.position[0].to_f * 2.54).round().to_s
                y = (v.position[1].to_f * 2.54).round().to_s
                z += "," + x + "," + y
            end
            zones.push(z)
            s.bounds.each do |b|
                b.glazings.each do |g|
                    h = self.calculate_height(g.face.vertices)
                    w = (g.area_m / h).round(2)
                    p = h.to_s + "," + w.to_s + "," + self.calculate_midpoint(g.face.vertices) + ","
                    if b.is_internal_edge
                        if paths_inner.include?(g.to_s)
                            paths.push(p + paths_inner[g.to_s] + "," + i.to_s + ",0")
                        else
                            paths_inner[g.to_s] = i.to_s
                        end
                    else
                        paths.push(p + "-1," + i.to_s + ",")
                        pi = pressure_input(wind_direction, bdh, b, g)
                        params += pi[0]
                        heights.push(pi[1])
                    end
                end
            end
            rv += s.area_m * s.height_m
        end
        # 调用xgb生成风压
        pressures = []
        xgbinput = MPath::DATA+"vent/xgb.input"
        xgboutput = MPath::DATA+"vent/xgb.output"
        File.write(xgbinput, params.chomp)
        if FileTest::exists?(xgboutput)
            File.delete(xgboutput)
        end
        code = ["from MoosasPy.simulation.airflow.pressure_model import callXgb"]
        code+= ["callXgb(\"#{xgbinput}\",\"#{xgboutput}\")"]
        MoosasUtils.exec_python("ventXgb.pyw",code)
        MoosasUtils.wait(MPath::DATA+"vent/xgb.output")
        File.open(MPath::DATA+"vent/xgb.output","r") do |file|
            index = 0
            while line = file.gets
                pressures.push((line.to_f * 1.205 * (wind_speed ** 2) * ((heights[index] / 10) ** (alpha * 2)) / 2).round(2)) 
                index += 1
            end
        end
        # 给paths添加风压
        index = 0
        for i in 0..paths.length - 1 do
            if paths[i][-1] == ','
                paths[i] += pressures[index].to_s
                index += 1
            end
        end
        # 调用contam执行模拟
        pwd = MPath::VENT
        Dir.chdir pwd
        File.write("zones", zones.join("\n"))
        File.write("paths", paths.join("\n"))
        if thermal
            p 'calculating radiance heat gain...'
            roomheat = self.calculate_rooomheat(model)
        else
            roomheat = model.simulation_spaces.map{ |s| 0.0  }
        end
        zone_name = model.simulation_spaces.map{ |s| s.settings["zone_name"]  }
        thermal_param=(0..roomheat.length-1).map{ |i| [zone_name[i],in_temp,roomheat[i]].join(",") }
        thermal_param.push(['Outdoor',out_temp,-1].join(","))
        File.write("roomheat", thermal_param.join("\n"))
        p 'executing afn.exe...'
        system("./afn/afn" + MPath::EXE_SUFFIX)
        if thermal 
            prjdict = MPath::VENT+"thermal"
            p 'executing Thermal Iteration...'
            self.run_auto_contamx($ontologies.first,t0=out_temp,max_iteration=10)
            # 等待result出现
            MoosasUtils.wait(MPath::DATA+"vent/result.csv")
            UI.openURL(MPath::DATA+"vent/result.csv")
        end
        # 输出建筑换气次数
        airVol=0
        # 等待airVol出现
        MoosasUtils.wait(pwd+"/airVol")
        Dir.chdir pwd
        File.open("airVol","r") do |file|
            airVol=file.gets.to_f 
        end

        # 可视化各外窗流量
        self.visualization(model,airVol/ rv)

        return (airVol/ rv).round(2)
    end

    def self.visualize_path(path_result,airVol)
    # Function:
    # Visualizes airflow paths and ventilation rates in a building model based on simulation results.
    # Draws directional arrows on glazing surfaces to represent air movement and computes room-specific ventilation metrics.
    # 
    # Parameters:
    # path_result : Hash
    # A dictionary containing airflow data for glazing elements, indexed by glazing UID.
    # Each entry includes 'flow' (volume flow rate in m³/h), 'from' (source space or 'ambient'), and 'to' (destination space or 'ambient').
    # airVol : float or int
    # Scaling factor or threshold value used in flow visualization; exact usage depends on downstream `flow_visualization` method.
    # 
    # Returns:
    # None
    # This method produces visual output (e.g., 3D arrows in the model) via side effects and does not return a value.
        arrowLines = {}
        vent = {}
        $current_model.simulation_spaces.each do |s|
            airVol_space=0
            s.bounds.each do |b|
                nor=b.normal
                nor.length=1
                b.glazings.each do |g|
                    if path_result.has_key?(g.uid)
                        vel = path_result[g.uid]['flow']/3600/g.area_m
                        # p path_result[g.uid]
                        # if path_result[g.uid]['from'] == 'ambient'
                        #     fromP = g.face.vertices[0]
                        # else
                        #     fromP = $current_model%(path_result[g.uid]['from'])
                        #     p fromP.id
                        #     fromP = fromP.get_weight_center()
                        # end
                        # if path_result[g.uid]['to'] == 'ambient'
                        #     toP = g.face.vertices[0]
                        # else
                        #     toP = $current_model%(path_result[g.uid]['to'])
                        #     p toP.id
                        #     toP = toP.get_weight_center()
                        # end
                        # nor_other = [fromP[0]-toP[0],fromP[1]-toP[1],fromP[2]-toP[2]]
                        #
                        # if nor.dot(toP-fromP)<0
                        #     nor.length=-1
                        # end
                        unless path_result[g.uid]['from'] == s.id
                            nor.length=-1
                        end
                        airVol_space += vel.abs() if b.is_internal_edge == false
                        arrowLines[g.uid] = self.draw_arrow(g,vel,nor)
                    end
                end
            end
            vent[s.id] = airVol_space.abs()*3600/2/s.area_m/s.height_m
        end
        self.flow_visualization(arrowLines.values,airVol)
        # self.room_visulization(vent)
    end
    def self.visualization(model,airVol)
    # Function:
    # Generates a visualization of airflow characteristics within a building model based on air velocity data.
    # Reads air velocity values from a file, computes airflow volume per space, and creates arrow-based visual representations
    # of airflow direction and magnitude across glazing surfaces. Also calculates ventilation rates for each space.
    # 
    # Parameters:
    # model : OpenStudio::Model::Model
    # The building energy model containing spaces, surfaces, and glazings used for spatial and geometric calculations.
    # airVol : Float
    # A scaling or threshold parameter related to air volume, passed to the flow visualization function;
    # purpose may depend on downstream visualization logic.
    # 
    # Returns:
    # None
    # This method does not return a value. It produces side effects including file reading, internal data processing,
    # and triggering visualization routines that may generate graphical output or files.
        airVel = {}
        File.open("airVel","r") do |file|
            while line = file.gets
                av = line.split("|")
                airVel[av[0]] = av[1].to_f
            end
        end
        arrowLines = {} 
        vent = {}
        simulation_spaces = model.simulation_spaces
        for i in 0..simulation_spaces.length - 1 do
            airVol_space=0
            s = simulation_spaces[i]
            s.bounds.each do |b|
                nor=b.normal
                nor.length=1
                b.glazings.each do |g|
                    vertices_=[]
                    s.floor.each{|floor| floor.face.vertices.each{|ver| vertices_.push(ver)}}
                    vel = airVel[self.calculate_midpoint(vertices_) + "," + self.calculate_midpoint(g.face.vertices)]
                    airVol_space += vel.abs()*g.area_m if b.is_internal_edge == false
                    arrowLines[g.id] = self.draw_arrow(g,vel,nor)
                end
            end
            vent[s.id] = airVol_space.abs()*3600/2/s.area_m/s.height_m
        end
        self.flow_visualization(arrowLines.values,airVol)
        #self.room_visulization(vent)
    end
    def self.calculate_bdh(model)
    # """
    # Function
    # --------
    # calculate_bdh : Calculates the bounding dimensions (length, width, height) of a 3D model based on its spatial geometry.
    # 
    # Parameters
    # ----------
    # model : OpenStudio::Model::Model
    # The OpenStudio model object containing spaces and associated geometry from which bounding dimensions are computed.
    # It is expected to have defined spaces with floor surfaces and vertices.
    # 
    # Returns
    # -------
    # Array<Float>
    # A three-element array representing the overall dimensions of the model in meters:
    # - [0]: Length (difference in X-axis: max - min)
    # - [1]: Width (difference in Y-axis: max - min)
    # - [2]: Height (difference in Z-axis: adjusted max - min, accounting for space height)
    # """
        domain = [1e+9, -1e+9, 1e+9, -1e+9, 1e+9, -1e+9]
        model.simulation_spaces.each do |s|
            vertices_=[]
            s.floor.each{|floor| floor.face.vertices.each{|ver| vertices_.push(ver)}}
            vertices_.each do |v|
                vx = (v.position[0].to_f * 0.0254).round(2)
                vy = (v.position[1].to_f * 0.0254).round(2)
                vz = (v.position[2].to_f * 0.0254).round(2)
                if vx < domain[0]
                    domain[0] = vx
                elsif vx > domain[1]
                    domain[1] = vx
                end
                if vy < domain[2]
                    domain[2] = vy
                elsif vy > domain[3]
                    domain[3] = vy
                end
                if vz < domain[4]
                    domain[4] = vz
                elsif vz > domain[5] - s.height_m
                    domain[5] = vz + s.height_m
                end
            end
        end
        return [domain[1] - domain[0], domain[3] - domain[2], domain[5] - domain[4]]
    end

    def self.calculate_midpoint(vertices)
    # Function:
    # Calculate the midpoint (centroid) of a set of 3D vertices, converting coordinates from inches to centimeters.
    # 
    # Parameters:
    # vertices : Array<Vertex>
    # An array of vertex objects, each having a `position` attribute that returns an array-like structure
    # containing three numerical values representing x, y, z coordinates in inches.
    # 
    # Returns:
    # String
    # A comma-separated string representing the rounded midpoint coordinates (x, y, z) in centimeters.
    # The format is "x,y,z" where each coordinate is rounded to the nearest integer.
        c, x, y ,z = 0, 0, 0, 0
        vertices.each do |v|
            c += 1
            x += v.position[0].to_f * 2.54
            y += v.position[1].to_f * 2.54
            z += v.position[2].to_f * 2.54
        end
        return (x / c).round.to_s + "," + (y / c).round.to_s + "," + (z / c).round.to_s
    end

    def self.calculate_height(vertices)
    # """
    # Function
    # --------
    # calculate_height
    # Calculates the height based on the Z-coordinate differences between specified vertices,
    # converts the result from inches to meters, and returns the rounded value.
    # 
    # Parameters
    # ----------
    # vertices : Array<Vertex>
    # An array of vertex objects, each having a `position` attribute that is an array-like
    # structure where the third element (index 2) represents the Z-coordinate in inches.
    # 
    # Returns
    # -------
    # Float
    # The calculated height in meters, converted from the largest of two consecutive
    # Z-coordinate differences (between vertices[1] and vertices[0], or vertices[2] and vertices[1]),
    # rounded to two decimal places.
    # """
        height = (vertices[1].position[2].to_f - vertices[0].position[2].to_f).abs
        backup = (vertices[2].position[2].to_f - vertices[1].position[2].to_f).abs
        if height < backup
            height = backup
        end
        return (height * 0.0254).round(2)
    end

    def self.pressure_input(wind_direction, bdh, b, g)
    # Function:
    # Computes normalized input parameters for pressure analysis based on wind direction, building dimensions,
    # geometric data, and orientation. The method calculates ratios of building height and depth, adjusts for
    # wind incidence angle, normalizes coordinates, and determines vertical and horizontal positions within
    # a defined domain.
    # 
    # Parameters:
    # wind_direction : float
    # The direction of the wind in degrees (0-360), used to compute the relative angle with the building orientation.
    # bdh : array_like of float
    # A 3-element array representing building depth, height, and another dimension (e.g., [depth, height, ?]).
    # Used to calculate aspect ratios.
    # b : object
    # A building-like object containing wall and face geometry information. Must have a `normal` property
    # and a `walls` collection where the first wall's vertices define a spatial domain.
    # g : object
    # A geometric face object (e.g., roof or surface) with vertices used to compute average height and horizontal
    # position. Must have a `face.vertices` collection with positional data.
    # 
    # Returns:
    # list
    # A two-element list:
    # - The first element is a comma-separated string of five normalized values:
    # db (normalized depth ratio), hb (normalized height ratio), theta (normalized wind angle),
    # height (relative vertical position), and horizon (relative horizontal position).
    # All values are rounded to two decimal places and scaled to the range [0,1], with horizon possibly flipped.
    # - The second element is the average z-coordinate (height in meters) of the vertices in `g.face.vertices`.
        ori, db, hb, index, reverse = calculate_orientation(b.normal), 0, 0, 0, 0
        if (ori > 45 and ori <= 135) or (ori > 225 and ori <= 315)
            db, hb = bdh[1] / bdh[0], bdh[2] / bdh[0]
        else
            db, hb = bdh[0] / bdh[1], bdh[2] / bdh[1]
            index = 1
        end
        theta = (ori - wind_direction).abs
        if theta > 180
            theta = 360 - theta
        end
        db, hb, theta = ((db - 0.4) / 2.1).round(2), ((hb - 0.1) / 0.9).round(2), (theta / 180).round(2)
        if db < 0
            db = 0
        elsif db > 1
            #db = g.face.vertices
            db = 1
        end
        if hb < 0
            hb = 0
        elsif hb > 1
            hb = 1
        end
        if ori <= 45 or ori > 225
            reverse = 1
        end
        domain = [1e+9, -1e+9, 1e+9, -1e+9]
        b.walls[0].face.vertices.each do |v|
            ht, hn = (v.position[2].to_f * 0.0254).round(2), (v.position[index].to_f * 0.0254).round(2)
            if ht < domain[0]
                domain[0] = ht
            elsif ht > domain[1]
                domain[1] = ht
            end
            if hn < domain[2]
                domain[2] = hn
            elsif hn > domain[3]
                domain[3] = hn
            end
        end
        ht, hn, c = 0, 0, g.face.vertices.length
        g.face.vertices.each do |v|
            ht += (v.position[2].to_f * 0.0254).round(2)
            hn += (v.position[index].to_f * 0.0254).round(2)
        end
        ht, hn = ht / c, hn / c
        height = ((ht - domain[0]) / (domain[1] - domain[0])).round(2)
        horizon = ((hn - domain[2]) / (domain[3] - domain[2])).round(2)
        if reverse == 1
            horizon = 1 - horizon
        end
        return [db.to_s + "," + hb.to_s + "," + theta.to_s + "," + height.to_s + "," + horizon.to_s + "\n", ht]
    end

    def self.calculate_orientation(n)
    # """
    # Function
    # --------
    # calculate_orientation
    # Calculates the orientation angle in degrees from a 2D vector.
    # 
    # Parameters
    # ----------
    # n : Array<Numeric>
    # A two-element array representing a 2D vector, where n[0] is the x-component
    # and n[1] is the y-component.
    # 
    # Returns
    # -------
    # Numeric
    # The orientation angle in degrees, measured clockwise from the positive x-axis,
    # normalized to the range [0, 360). If the angle is exactly 360, it is returned as 0.
    # """
        o = Math.acos((-1) * (n[0]) / Math.sqrt((n[0])**2 + (n[1])**2)) * 180 / Math::PI
        if n[1] > 0
            o = 360-o
        end
        if o == 360
            o = 0
        end
        return o
    end

    def self.draw_arrow(g,vel,nor)
    # Function
    # --------
    # Computes and returns the centroid of a given geometry, along with a scaled direction vector
    # based on surface normal and velocity. This method is typically used to determine an arrow's
    # position and orientation in 3D space.
    # 
    # Parameters
    # ----------
    # g : Sketchup::Group or Sketchup::Face
    # The geometric entity (group or face) whose transformation and vertices are used
    # to compute the centroid and orientation.
    # vel : Float
    # The magnitude (length) of the output vector. If zero, it is set to 0.01 to avoid null vectors.
    # nor : Array<Float> or Geom::Vector3d
    # A 3D vector representing the normal direction. It will be converted into a Geom::Vector3d
    # and resized to the specified velocity magnitude.
    # 
    # Returns
    # -------
    # Array
    # An array containing:
    # - centroid (Geom::Point3d): The average center point of the face vertices in world coordinates.
    # - vector (Geom::Vector3d): The normalized normal vector scaled by `vel`.
    # - vel (Float): The applied velocity (vector magnitude), after correction if originally zero.
        #p nor
        vel=0.01 if vel==0
        c, x, y ,z = 0, 0, 0, 0
        transformation=g.transformation
        g.face.vertices.each do |v|
            pt = transformation * v.position
            c += 1
            x += pt[0].to_f
            y += pt[1].to_f
            z += pt[2].to_f
        end
        x, y, z = x / c, y / c, z / c
        #nx, ny = n[0] / Math.sqrt((n[0])**2 + (n[1])**2), n[1] / Math.sqrt((n[0])**2 + (n[1])**2)
        centroid = Geom::Point3d.new(x,y,z)
        vector = Geom::Vector3d.new(nor)
        vector.length=vel
        return [centroid,vector,vel]
        #puts nx,ny
        #sx, sy, ex, ey = x, y, x + nx * l, y + ny * l
        #if l < 0
        #    sx, sy, ex, ey = x - nx * l, y - ny * l, x, y
        #end

        #a1 = [[ex, ey, z], [sx, sy, z]]
        #a2 = [[ex, ey, z], [(sx + ex) / 2, (sy + ey) / 2, z + l *0.5]]
        #a3 = [[ex, ey, z], [(sx + ex) / 2, (sy + ey) / 2, z - l *0.5]]
        #return [a1, a2, a3]
    end

    def self.flow_visualization(arrowLines,airVol)
    # Function:
    # Generates a 3D visualization of airflow patterns on windows in a SketchUp model, using arrow glyphs to represent air velocity and direction.
    # The method creates a legend panel with a color scale based on velocity magnitude and annotates each arrow with its corresponding speed.
    # 
    # Parameters:
    # arrowLines (Array<Array>): A list of arrays, where each sub-array contains three elements:
    # - centroid (Geom::Point3d): The base point of the airflow arrow.
    # - direction_vector (Geom::Vector3d): The directional vector of the airflow.
    # - velocity (Numeric): The magnitude of airflow velocity (in m/s), used for scaling and coloring.
    # airVol (Numeric): The total air change per hour (ACH), displayed in the description panel.
    # 
    # Returns:
    # Sketchup::Entities — The entities collection within a newly created group that contains all visual elements (arrows, text labels, and legend panel) added to the active model.
        scale = 3/0.0254
        ent = Sketchup.active_model.entities.add_group
        ent=ent.entities

        # calculate the maximum
        vel_max = 0
        for i in 0..arrowLines.length - 1 do
            al = arrowLines[i]
            vel_max=[vel_max,al[2].to_f.abs()].max
        end
        vel_max=vel_max.round(1)
        description="Air Speed on Windows\nLocation:#{MoosasWeather.singleton.station_info["city"]}\nCodition:Wind pressure natural ventilation\nPriod:Summer\nTotal Air Change:#{airVol.round(2)} ACH"
        scaleRender=MoosasGridScaleRender.new(0,vel_max,description = description,unit='m/s',colors=[Sketchup::Color.new("Blue"),Sketchup::Color.new("Green"), Sketchup::Color.new("Yellow"),Sketchup::Color.new("Red")])
        scaleRender.draw_panel(Sketchup.active_model.selection)

        # draw arrow
        for i in 0..arrowLines.length - 1 do
            al = arrowLines[i]

            centroid = al[0]
            airarrow = Geom::Vector3d.new(al[1])
            horizonal = airarrow*Geom::Vector3d.new(0,0,1)
            vel = al[2]

            airarrow.length = vel.to_f.round(2).abs()*scale/2
            horizonal.length = airarrow.length/10

            ventilation_bar=ent.add_face([
                centroid-horizonal,
                centroid+horizonal,
                centroid+horizonal+airarrow,
                centroid+airarrow+airarrow,
                centroid-horizonal+airarrow,
            ])
            ventilation_bar.material = scaleRender.get_color(vel.to_f.round(2).abs())
            ventilation_bar.back_material = ventilation_bar.material
            lgtext = ent.add_group
            lgtext.entities.add_3d_text(vel.to_f.round(2).abs().to_s+'m/s',TextAlignLeft,"Arial",false,false,horizonal.length*2)
            lgtext.move!(centroid+Geom::Vector3d.new([0,0,0.1]))
            angle = airarrow.angle_between(Geom::Vector3d.new([1,0,0]))
            angle = -angle if airarrow[1]<0
            lgtext.transform!(Geom::Transformation.rotation(centroid,Geom::Vector3d.new([0,0,1]),angle))
            lgtext.material = Sketchup::Color.new ("Black")
        end
    end

    def self.room_visulization(vent)
    # Function:
    # Visualizes air change rates (in ACH) for rooms in a SketchUp model using colored 3D text labels.
    # The method creates a group of entities, assigns colors based on ventilation values,
    # and places labeled 3D text at the center of each room to represent its air change coefficient.
    # 
    # Parameters:
    # vent : Hash
    # A dictionary mapping space IDs to their respective air change per hour (ACH) values.
    # Keys are identifiers for spaces, and values are numerical air change coefficients.
    # 
    # Returns:
    # None
    # This method does not return a value. It modifies the SketchUp model by adding visual elements
    # (colored 3D text labels) to represent ventilation data within the model space.
        ent = Sketchup.active_model.entities.add_group
        ent=ent.entities
        description="Air Change Coefficiency of Rooms\nLocation:#{MoosasWeather.singleton.station_info["city"]}\nCodition:Wind pressure natural ventilation\nPriod:Summer"
        scaleRender=MoosasGridScaleRender.new(0,vent.values.max.round(1),description = description,unit='ACH',colors=[Sketchup::Color.new("Blue"),Sketchup::Color.new("Green"), Sketchup::Color.new("Yellow"),Sketchup::Color.new("Red")])
        #scaleRender.draw_panel(Sketchup.active_model.selection,origin=Geom::Vector3d.new([0,1,0]))
        $current_model.simulation_spaces.each{|space|
            col = scaleRender.get_color(vent[space.id])
            ach_text= vent[space.id].round(1).to_s + "ACH"
            lgtext = ent.add_group
            lgtext.entities.add_3d_text(ach_text,TextAlignCenter,"Arial",false,false,Math.sqrt(space.area_m)*4.5)
            midpoint=space.get_weight_center()
            lgtext.move!(Geom::Vector3d.new(midpoint)+Geom::Vector3d.new([-Math.sqrt(space.area_m)*12,0,0.1]))
            lgtext.material = col
            }
    end

    def self.run_auto_contamx(model_file,t0 = 20,max_iteration = 10)
    # """
    # Function
    # --------
    # Run the automatic CONTAM simulation process using the new AirflowRunner API.
    # 
    # The old implementation depended on the removed `iterateProjects` helper and
    # generated legacy project lists. The new package accepts a model directly and
    # returns zone temperatures and ACH values through AirflowRunner.
    # 
    # Parameters
    # ----------
    # model_file : str
    # Path to a serialized MoosasPy model.
    # t0 : float, optional
    # Outdoor temperature setting for the simulation (default is 20°C).
    # max_iteration : int, optional
    # Maximum number of iterations allowed in the simulation process (default is 10).
    # 
    # Returns
    # -------
    # bool
    # Returns True if the simulation script executes successfully without exceptions.
    # Returns False if an exception occurs during system execution, after logging the error.
    # """
        code = [
            "from MoosasPy.model.io import load_model",
            "from MoosasPy.simulation.airflow import AirflowRunner",
            "import csv",
            "model = load_model('#{MPath.python_path(model_file)}')",
            "heat_loads = {}",
            "with open('#{MPath.python_path(MPath::VENT+"roomheat")}',newline='',encoding='utf-8') as heat_file:",
            "    for row in csv.reader(heat_file):",
            "        if len(row) >= 3 and row[0] != 'Outdoor': heat_loads[row[0]] = float(row[2])",
            "runner = AirflowRunner(model,outdoor_temperature=#{t0},heat_loads=heat_loads or None,max_iterations=#{max_iteration})",
            "result = runner.run()",
            "with open('#{MPath.python_path(MPath::DATA+"vent/result.csv")}','w',newline='',encoding='utf-8') as result_file:",
            "    writer = csv.writer(result_file)",
            "    writer.writerow(['zone','temperature','ach'])",
            "    for zone in result.zones: writer.writerow([zone.user_name,zone.temperatures[-1],zone.ach_values[-1]])"
        ]
        begin
            return MoosasUtils.exec_python("auto_contam.pyw",code,true)
        rescue => e
            MoosasUtils.rescue_log(e)
            return false
        end
    end

    def self.calculate_rooomheat(model)
    # Function:
    # Calculate the total heat load for each room in the building model, including solar radiation, occupant heat gain, equipment heat gain, and lighting heat gain.
    # 
    # Parameters:
    # model : OpenStudio::Model::Model
    # The OpenStudio model object containing the building spaces and thermal zones.
    # Used to access space-level settings and geometric properties for heat load calculation.
    # 
    # Returns:
    # roomheat : Array<Float>
    # An array of total heat loads in watts for each space in the model.
    # Each element represents the summed heat gain from solar radiation, occupants,
    # equipment, and lighting for the corresponding space.

        t2 = Time.new
            $current_model.simulation_spaces.each{ |s| 
                #p "#{s.id}:#{s.settings['zone_summerrad']}"
                if s.settings['zone_summerrad'] == nil
                    s.calculate_zone_radation(model)
                end   
            }
        MoosasUtils.backup_setting_data()
        
        t3 = Time.new
        p "辐射计算用时： #{t3-t2}s"

        roomheat = []
        model.simulation_spaces.each{ |s|
            heat = s.settings['zone_summerrad'].to_f / (5832-3624)*1000
            heat += s.settings['zone_ppsm'].to_f * s.settings['zone_popheat'].to_f * s.area_m
            heat += s.settings['zone_equipment'].to_f * s.area_m
            heat += s.settings['zone_lighting'].to_f * s.area_m
            roomheat.push(heat)
          }
        return roomheat
    end
end
