
#encoding: utf-8
require 'open-uri'
require 'csv'
require 'set'
require 'fileutils'
require 'tmpdir'
require 'json'

'''
    处理气象数据的函数
'''
class MoosasWeather
    Ver='0.6.4'
    class << self
        attr_accessor :singleton, :station_id #单例，全局变量
        attr_reader :stations
    end
    attr_accessor :station_info, :station_id, :weather_data, :climate_zone

    @stations ||= {}
    @station_id ||= "545110"   #当前选中的气象站id
    @station_info = nil #当前选中的气象站信息
    @weather_data = nil #当前的气象数据
    @climate_zone = "climate_zone3"

    def self.load_data()
    # """
    # Function
    # --------
    # Loads and initializes weather data for a default station (Beijing) and creates a new instance of cumulative sky data.
    # 
    # This method invokes the weather station data loading process, sets the station ID to "545110" (corresponding to Beijing),
    # initializes the singleton instance of MoosasWeather, and instantiates a new MoosasCumSky object using the selected station ID.
    # It serves as an initialization routine for weather and sky condition data processing.
    # 
    # Parameters
    # ----------
    # None
    # This method does not accept any parameters.
    # 
    # Returns
    # -------
    # MoosasCumSky
    # A new instance of MoosasCumSky initialized with the default station ID ("545110").
    # The returned object represents cumulative sky conditions data for the specified station.
    # 
    # Notes
    # -----
    # - The station ID is hardcoded to "545110", which refers to Beijing.
    # - The method relies on the MoosasWeather class to load and store weather station data.
    # - The MoosasCumSky instance is stored in the global variable `$current_CumSky`.
    # """
        MoosasWeather.load_weather_stations_data
        MoosasWeather.station_id = @stations.key?('545110') ? '545110' : @stations.keys.first
        return unless MoosasWeather.station_id
        MoosasWeather.load_singleton
        #MoosasWebDialog.send("update_weather_chart",{"weather"  => MoosasWeather.singleton.to_json_string()})
        $current_CumSky = MoosasCumSky.new(MoosasWeather.station_id)
        
    end

    def self.reset_weather_data_to_ui
        MoosasWebDialog.send('weather_import_status', {'running'=>!!@import_running})
        load_weather_stations_data
        preferred = ($ui_settings || {})['selectCity'].to_s
        @station_id = preferred if @stations.key?(preferred)
        @station_id = @stations.key?(@station_id.to_s) ? @station_id.to_s : @stations.keys.first
        $ui_settings ||= {}
        $ui_settings['selectCity'] = @station_id
        MoosasWebDialog.send('load_weather_stations_data', {'stations'=>@stations, 'station_id'=>@station_id})
        raise '没有可用气象数据，请使用 Load EPW 导入。' unless @station_id
        update_weather_station(@station_id)
    rescue => e
        MoosasWebDialog.send('weather_error', {'message'=>e.message})
    end

    def self.update_weather_station(sid)
        load_weather_stations_data
        sid = sid.to_s
        raise "气象站不可用: #{sid}" unless @stations.key?(sid) && File.file?(File.join(MPath::WEATHER, sid + '.csv'))
        weather = new
        weather.get_city_station_weather_data(sid)
        @station_id, @singleton, $weather = sid, weather, weather
        $ui_settings ||= {}
        $ui_settings['selectCity'] = sid
        # Main Python analysis loads its own sky. Never retain a different station's sky.
        $current_CumSky = File.file?(File.join(MPath::SKY, "cumsky_#{sid}.csv")) ? MoosasCumSky.new(sid) : nil
        MoosasWebDialog.send('update_weather_chart', {'station_id'=>sid, 'weather'=>weather.weather_data})
        sid
    rescue => e
        $ui_settings['selectCity'] = @station_id if $ui_settings
        MoosasWebDialog.send('weather_error', {'station_id'=>@station_id, 'message'=>e.message})
        false
    end

    def self.write_station_rows(rows)
        destination = File.join(MPath::WEATHER_LIB, 'dest_station.csv')
        if File.file?(destination)
            backup = destination + '.' + Time.now.strftime('%Y%m%d-%H%M%S-%6N') + '.bak'
            FileUtils.cp(destination, backup)
            @station_backup = backup
        end
        temporary = destination + '.tmp'
        CSV.open(temporary, 'w', encoding: 'UTF-8') { |csv| rows.each { |row| csv << row } }
        File.rename(temporary, destination)
    end

    def self.load_weather_stations_data
        raise 'Weather directory is unavailable' unless Dir.exist?(MPath::WEATHER)
        destination = File.join(MPath::WEATHER_LIB, 'dest_station.csv')
        rows = File.file?(destination) ? CSV.read(destination, encoding: 'bom|utf-8') : []
        available = Dir.glob(File.join(MPath::WEATHER, '*.csv')).map { |path| File.basename(path, '.csv') }.to_set
        kept = rows.select { |row| row[0] && available.include?(row[0].strip) }
        @removed_station_ids = (rows - kept).map(&:first)
        write_station_rows(kept) unless rows == kept
        @stations = {}
        kept.each do |row|
            next unless row.length >= 7
            sid = row[0].strip
            @stations[sid] = {'sid'=>sid, 'city'=>row[1], 'province'=>row[2],
                'lat'=>row[3].to_f, 'lng'=>row[4].to_f, 'ele'=>row[5].to_f, 'airP'=>row[6].to_f}
        end
        @stations
    end

    def self.update_weather_stations_data(city,write=true)
    # """
    # Function
    # --------
    # Update weather station data for a given city and optionally write the updated data to a CSV file.
    # 
    # Parameters
    # ----------
    # city : Array
    # An array containing city data in the following order:
    # [station_id, city_name, province_name, latitude, longitude, elevation, air_pressure].
    # The first element (station_id) is used as the key in the internal `@stations` hash.
    # write : bool, optional
    # If True (default), writes the updated stations data to the destination CSV file.
    # If False, only updates the in-memory data without persisting to disk.
    # 
    # Returns
    # -------
    # None
    # This method does not return any value. It modifies the class-level instance variable `@stations`
    # and optionally writes the updated data to a file.
    # """
        #更新气象数据数据站点参数，先加载再更新
        @stations[city[0].to_s]={"sid"=>city[0].to_s,
                        "city"=>city[1],
                        "province"=>city[2],
                        "lat"=>city[3].to_f,
                        "lng"=>city[4].to_f,
                        "ele"=>city[5].to_f,
                        "airP"=>city[6].to_f}
        if write
            begin
                write_station_rows(@stations.values.map { |s| %w[sid city province lat lng ele airP].map { |key| s[key] } })
            rescue Exception => e
                MoosasUtils.rescue_log(e)
                p "写入气象数据失败"
            end
        end
    end

    def self.load_singleton()
    # """
    # Function
    # ----------
    # load_singleton
    # Initializes and loads weather data for the singleton instance of MoosasWeather.
    # If no station ID is set, assigns a default station ID. Then fetches the city and station weather data
    # using the station ID and stores the singleton instance in the global variable `$weather`.
    # 
    # Parameters
    # ----------
    # None
    # This method does not take any parameters.
    # 
    # Returns
    # -------
    # MoosasWeather
    # Returns the singleton instance of MoosasWeather after loading the weather data.
    # """
        MoosasWeather.singleton = MoosasWeather.new
        if MoosasWeather.station_id == nil
            MoosasWeather.station_id = "545110"
        end
        MoosasWeather.singleton.get_city_station_weather_data(MoosasWeather.station_id)
        $weather = MoosasWeather.singleton
    end

    #返回气象数据
    def self.get_weather_stations()
    # """
    # Function
    # --------
    # Organizes weather stations by province.
    # 
    # Parameters
    # ----------
    # None
    # This is a class method with no parameters.
    # 
    # Returns
    # -------
    # Hash
    # A hash where keys are province names (as strings) and values are arrays of station data hashes.
    # Each station data hash contains information about a weather station.
    # """
        ret = Hash.new
        @stations.each do |k,v|
            if ret[v["province"]] == nil
                ret[v["province"]] = []
            end     
            ret[v["province"]].push(v)
        end
        return ret
    end

    def self.get_all_stations_id()
    # """
    # Function
    # --------
    # Retrieve all station IDs from the class-level stations collection.
    # 
    # Parameters
    # ----------
    # None
    # 
    # Returns
    # -------
    # Array
    # A list of station IDs (strings or integers) extracted from the 'sid' field of each station in @stations.
    # """
        ids =  []
        @stations.each do |k,v|
            ids.push(v["sid"])
        end
        return ids 
    end

    def initialize()
    # """
    # Function
    # --------
    # Initializes a new instance of the class.
    # 
    # Parameters
    # ----------
    # None
    # This constructor does not accept any parameters.
    # 
    # Returns
    # -------
    # None
    # This method does not return a value; it is used for object initialization only.
    # """
    end

    def self.include_epw_file
        return false if @import_running
        chosen = UI.openpanel('Load EPW', nil, 'EnergyPlus Weather (*.epw)|*.epw||')
        if chosen
            execute_MoosasWeather(chosen)
        else
            reset_weather_data_to_ui
            false
        end
    end

    def self.execute_MoosasWeather(epw_file, cityname=nil, pwd=MPath::PYTHON)
        return false if @import_running
        raise '请选择有效 EPW 文件。' unless File.file?(epw_file) && File.extname(epw_file).downcase == '.epw'
        FileUtils.mkdir_p(File.join(MPath::DATA, 'jobs'))
        job = Dir.mktmpdir('weather-import-', File.join(MPath::DATA, 'jobs'))
        @import_job = job
        FileUtils.cp(epw_file, File.join(job, 'source.epw'))
        File.write(File.join(job, 'request.json'), JSON.generate({'city'=>cityname}), encoding: 'UTF-8')
        @import_running = true
        MoosasWebDialog.send('weather_import_status', {'running'=>true})
        started = MoosasUtils.exec_python_async('import_weather.py', [
            'from skp.scripts.import_station import prepare_station',
            "prepare_station(#{job.to_json})"
        ], workspace: job) do |success|
            begin
                result_file = File.join(job, 'result.json')
                unless success && File.file?(result_file)
                    error_file = File.join(job, 'error.json')
                    raise(File.file?(error_file) ? JSON.parse(File.read(error_file, encoding: 'UTF-8'))['message'] : 'EPW 导入失败，请检查任务日志。')
                end
                result = JSON.parse(File.read(result_file, encoding: 'UTF-8'))
                sid = result.fetch('station').fetch(0)
                raise 'Invalid station ID' unless sid.match?(/\A[0-9]+\z/)
                # Publish validated assets before adding the station to the index.
                [[result['weather_file'], File.join(MPath::WEATHER, sid + '.csv')],
                 [File.join(job, 'source.epw'), File.join(MPath::WEATHER, sid + '.epw')],
                 [result['sky_file'], File.join(MPath::SKY, 'cumsky_' + sid + '.csv')]].each do |input, output|
                    FileUtils.mkdir_p(File.dirname(output))
                    FileUtils.cp(output, File.join(job, 'previous-' + File.basename(output))) if File.file?(output)
                    FileUtils.cp(input, output + '.tmp')
                    File.rename(output + '.tmp', output)
                end
                load_weather_stations_data
                rows = @stations.reject { |id, _| id == sid }.values.map { |s| %w[sid city province lat lng ele airP].map { |key| s[key] } }
                write_station_rows(rows + [result['station']])
                $ui_settings ||= {}
                $ui_settings['selectCity'] = sid
                reset_weather_data_to_ui
            rescue => e
                MoosasWebDialog.send('weather_error', {'station_id'=>@station_id, 'message'=>e.message})
            ensure
                @import_running = false
                MoosasWebDialog.send('weather_import_status', {'running'=>false})
            end
        end
        raise '无法启动 EPW 导入进程。' unless started
        true
    rescue => e
        @import_running = false
        MoosasWebDialog.send('weather_import_status', {'running'=>false})
        MoosasWebDialog.send('weather_error', {'station_id'=>@station_id, 'message'=>e.message})
        false
    end

    def get_climate_zone(temperture)
    # Function:
    # Determines the climate zone for building thermal design based on temperature data, following the Chinese standard GB 50176.
    # The classification primarily uses the average temperatures of the coldest month (January) and hottest month (July),
    # with secondary indicators being the number of days with daily average temperature ≤5°C or ≥25°C.
    # 
    # Parameters:
    # temperture : Array<Numeric>
    # An array of hourly temperature values over a year, expected to be 8760 elements long (365 days × 24 hours).
    # This method converts it into daily average temperatures for further analysis.
    # 
    # Returns:
    # String
    # A string representing the climate zone classification as defined by GB 50176, one of:
    # "climate_zone1", "climate_zone2", "climate_zone3", "climate_zone4", or "climate_zone5",
    # based on primary (monthly averages) and secondary (cumulative degree-day) criteria.
        '''
        《民用建筑设计统一标准》GB 50352 《建筑气候区划标准》GB 50178规定建筑气候区划;
        《民用建筑热工设计规范》GB 50176规定建筑热工设计分区;
        MOOSAS采用GB 50176规定的建筑热工设计分区,主要体现在气象基本要素对建筑物及围护结构的保温隔热设计的影响。
        建筑热工设计分区用累年最冷月（即1月）和最热月（即7月）平均温度作为分区主要指标，
        累计日平均温度≤5度和≥25度的天数作为辅助指标。

        '''
        doy = [31,28,31,30,31,30,31,31,30,31,30,31]
        (1..11).to_a.each{ |mon| doy[mon] = doy[mon] + doy[mon-1]  }
        temperture = temperture.each_slice(24).to_a.map{ |day| day.sum / day.length } #日平均温度
        tmin_m = temperture[0,doy[0]].sum / temperture[0,doy[0]].length #最冷月平均温度——1月
        tmax_m = temperture[doy[5],31].sum / 31.0 #最热月平均温度——7月
        d_5 = temperture.map{ |day| 1 if day<5 }.count(1) # 累计日平均温度≤5度
        d_25 = temperture.map{ |day| 1 if day>25 }.count(1) # 累计日平均温度≥25度

        #优先主要指标
        if tmin_m<=-10 
            return "climate_zone1"
        elsif tmin_m<=0 
            return "climate_zone2"
        elsif tmin_m<=10 and tmax_m>25 and tmax_m<=30 
            return "climate_zone3"
        elsif tmin_m>10 and tmax_m>25 and tmax_m<=29 
            return "climate_zone4"
        elsif tmin_m>0 and tmin_m<=13 and tmax_m>18 and tmax_m<=25 
            return "climate_zone5"
        end

        #其次次要指标
        if d_5>=145 
            return "climate_zone1"
        elsif d_5>=90 
            return "climate_zone2"
        elsif d_25>=40 and d_25 <110 
            return "climate_zone3"
        elsif d_25 <200 
            return "climate_zone4"
        else 
            return "climate_zone5"
        end
    end

    #根据气象站的id加载气象数据
    def get_city_station_weather_data(sid)
    # """
    # Function
    # --------
    # Retrieve weather data for a specified station ID and compute associated climate zone.
    # 
    # Parameters
    # ----------
    # sid : String or Integer
    # The station ID used to locate the corresponding weather data file.
    # This ID is used to access station metadata and load the associated CSV file.
    # 
    # Returns
    # -------
    # Array<Hash>
    # An array of hashes containing parsed weather data records. Each hash includes:
    # - "t" : Float, temperature (°C)
    # - "d" : Float, moisture content (g/kg)
    # - "gt" : Float, ground surface temperature (°C)
    # - "p" : Float, atmospheric pressure (hPa)
    # - "rt" : Float, global solar radiation (W/m²)
    # - "ws" : Float, wind speed (m/s)
    # - "wd" : Float, wind direction (degrees from north)
    # 
    # If file reading fails, returns an empty array and logs the error.
    # """
        #if @station_id == sid
        #    return @weather_data
        #end

        @station_id = sid
        @station_info = MoosasWeather.stations[sid]
        @weather_data = []
        raise "Missing weather CSV for station #{sid}" unless File.file?(MPath::WEATHER+"#{sid}.csv")
        begin
            File.open(MPath::WEATHER+"#{sid}.csv","r") do |file|
                while line = file.gets  
                    arr = line.split(',')
                    @weather_data.push(
                        {
                            "t"=>arr[3].to_f,
                            "d"=>arr[4].to_f,
                            "gt"=>arr[7].to_f,
                            "p"=>arr[11].to_f,
                            "rt"=>arr[5].to_f,
                            "ws"=>arr[9].to_f,
                            "wd"=>arr[10].to_f
                        })  #温度、含湿量、地表温度、气压强度、水平总辐射、风速、风向
                end  
            end

            #在模型中存储城市数据
            #MoosasMeta.set_city(pn+","+sid)
        rescue Exception => e
            MoosasUtils.rescue_log(e)
            p "加载气象站点的数据失败"
        end
        @climate_zone = self.get_climate_zone(@weather_data.map{ |day| day["t"] })
        return @weather_data
    end

    def get_weather_in_days()
    # """
    # Function
    # --------
    # get_weather_in_days
    # Splits the hourly weather data into daily segments, each containing 24 hours of data.
    # 
    # Parameters
    # ----------
    # None
    # This method does not take any parameters. It operates on the instance variable `@weather_data`.
    # 
    # Returns
    # -------
    # days : list of lists
    # A list where each element is a sublist representing one day's worth of weather data.
    # Each sublist contains 24 consecutive elements from `@weather_data`, corresponding to 24 hours.
    # The total number of days is determined by integer division of the length of `@weather_data` by 24.
    # """
        days = []
        dN = @weather_data.length / 24 #获取天数
        for d in 0..dN-1 do
            days.push(@weather_data[24*d..24*d+23])
        end
        return days
    end

    ''' 
        计算夜间室外平均温度
    '''
    def calculate_ave_out_tem_night(day,workStart, workEnd)
    # """
    # Function
    # --------
    # calculate_ave_out_tem_night
    # Calculates the average outdoor temperature during nighttime hours, excluding the working period.
    # 
    # Parameters
    # ----------
    # day : Array<Hash>
    # An array of 24 hashes representing hourly data for a single day. Each hash must contain a key "t" representing the temperature at that hour.
    # workStart : Integer
    # The starting hour of the work period (1-based index), used to determine the beginning of the excluded interval.
    # workEnd : Integer
    # The ending hour of the work period (1-based index), used to determine the end of the excluded interval.
    # 
    # Returns
    # -------
    # Float
    # The average temperature during the non-working (nighttime) hours. This is computed as the mean of the "t" values from the hours before `workStart` and after `workEnd-1`, inclusive.
    # """
        arr = day[0..workStart-2] + day[workEnd-1..23]
        ave = 0
        arr.each do |a|
            ave += a["t"]
        end
        return ave / arr.length
    end


    #初始化冬夏季时间
    def init_summer_winter_day_number(settings)
    # Function:
    # Initializes the day-of-year numbers for the start and end dates of summer and winter seasons based on provided settings.
    # Stores the computed day numbers as instance variables (@sStartN, @sEndN, @wStartN, @wEndN) for later use in seasonal calculations.
    # 
    # Parameters:
    # settings : Hash
    # A hash containing configuration values with the following required keys:
    # - "year" : Integer, the year for which the day numbers are calculated.
    # - "sStartM": Integer, the month of the summer start date.
    # - "sStartD": Integer, the day of the summer start date.
    # - "sEndM"  : Integer, the month of the summer end date.
    # - "sEndD"  : Integer, the day of the summer end date.
    # - "wStartM": Integer, the month of the winter start date.
    # - "wStartD": Integer, the day of the winter start date.
    # - "wEndM"  : Integer, the month of the winter end date.
    # - "wEndD"  : Integer, the day of the winter end date.
    # 
    # Returns:
    # None
    # This method does not return a value. It sets the following instance variables:
    # - @sStartN : Integer, day of the year for summer start date.
    # - @sEndN   : Integer, day of the year for summer end date.
    # - @wStartN : Integer, day of the year for winter start date.
    # - @wEndN   : Integer, day of the year for winter end date.
        t = Time.new(settings["year"], settings["sStartM"], settings["sStartD"])
        @sStartN = t.yday
        t = Time.new(settings["year"], settings["sEndM"], settings["sEndD"])
        @sEndN = t.yday
        t = Time.new(settings["year"], settings["wStartM"], settings["wStartD"])
        @wStartN = t.yday
        t = Time.new(settings["year"], settings["wEndM"], settings["wEndD"])
        @wEndN = t.yday
    end

    #计算当前日处于什么季节
    def calculate_day_type(d)
    # """
    # Function
    # --------
    # calculate_day_type
    # Determines the type of day based on a given day number relative to predefined
    # start and end days of summer and winter periods.
    # 
    # Parameters
    # ----------
    # d : Integer
    # The day number (e.g., day of the year) to be classified. Assumed to be a valid
    # numeric value representing a calendar day.
    # 
    # Returns
    # -------
    # Integer
    # Returns an integer indicating the day type:
    # - 1 if the day falls within the summer period (inclusive of boundaries),
    # - 2 if the day falls within the winter period (inclusive of boundaries, with possible wrap-around logic),
    # - 0 if the day falls in neither summer nor winter, i.e., considered a shoulder or neutral period.
    # """
        #夏季
        if d >= @sStartN and d <= @sEndN
            return 1
        end
        #冬季
        if d >= @wStartN or d <= @wEndN
            return 2
        end
        return 0
    end

    '''
    def self.get_year_enthalpy()
    # """
    # Function
    # --------
    # Computes the enthalpy values for each weather data entry across a year.
    # 
    # This method iterates over the class-level weather data array (`@weather_data`),
    # calculates the enthalpy for each record using temperature (`t`) and absolute humidity (`d`)
    # via the `MoosasThermalLoad.calculate_enthalpy_using_absolute_humandity` method,
    # and collects the results in an array.
    # 
    # Parameters
    # ----------
    # None
    # This is a class method that uses the class variable `@weather_data` which is expected
    # to be an array of hashes, each containing at least the keys:
    # - "t" : float or int
    # Temperature value (unit typically in °C unless otherwise specified).
    # - "d" : float or int
    # Absolute humidity value (typically in kg moisture/kg dry air).
    # 
    # Returns
    # -------
    # list of float
    # An array containing the calculated enthalpy values for each weather data point,
    # in the same order as `@weather_data`. Each value represents the specific enthalpy
    # computed from the corresponding temperature and humidity.
    # """
        ens = []
        #myFile = File.new("C:/Users/dell/Desktop/en.csv","w");  
    
        @weather_data.each do |w|
            #ens.push(MoosasThermalLoad.calculate_enthalpy_using_absolute_humandity(w["t"],w["d"]))
            e = MoosasThermalLoad.calculate_enthalpy_using_absolute_humandity(w["t"],w["d"])
            ens.push(e)
            #myFile.puts(e)
            #p e
        end
        #myFile.close
        ens
    end
    '''

    def get_station_id
    # """
    # Function
    # ----------
    # get_station_id
    # Returns the value of the instance variable @station_id.
    # 
    # Parameters
    # ----------
    # None
    # 
    # Returns
    # -------
    # @station_id : any type
    # The current value of the instance variable @station_id. The return type depends on what has been assigned to @station_id.
    # """
        return @station_id
    end

    def to_array()
    # """
    # Function
    # ----------
    # Converts weather data into an array of temperature values.
    # 
    # Parameters
    # ----------
    # None
    # 
    # Returns
    # -------
    # List[List[float or Any]]
    # A list of lists, where each inner list contains the temperature value (from key "t")
    # of a weather data entry. Currently, only the temperature field is extracted and included.
    # """
        jsa = []
        @weather_data.each do |wd|
            a = [wd["t"]]#,wd["d"],wd["gt"],wd["p"],wd["rt"],wd["ws"],wd["wd"]]
            jsa.push(a)
        end
        return jsa
    end

    def to_json_string()
    # Function:
    # Converts the weather data stored in the instance variable @weather_data into a JSON-formatted string representation.
    # Each weather data entry is transformed into a JSON object with abbreviated field names and then combined into a JSON array.
    # 
    # Parameters:
    # None
    # 
    # Returns:
    # str: A JSON-formatted string representing an array of weather data objects.
    # Each object contains the following fields:
    # - t: temperature
    # - d: date or time
    # - gt: ground temperature (or similar measurement)
    # - p: pressure
    # - rt: real-time value (or reading time)
    # - ws: wind speed
    # - wd: wind direction
        jsa = []
        @weather_data.each do |wd|
            a = "{\"t\":#{wd["t"]},\"d\":#{wd["d"]},\"gt\":#{wd["gt"]},\"p\":#{wd["p"]},\"rt\":#{wd["rt"]},\"ws\":#{wd["ws"]},\"wd\":#{wd["wd"]}}"
            jsa.push(a)
        end
        js = "[" + jsa.join(",")+ "]"
    end

end
