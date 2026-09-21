/**
 * SKP: 发送给ruby、接受ruby信息
 */
Skp = {};
Skp.PAYLOAD_DELIMITER = "|";
Skp.PAYLOAD_PARAMS_DELIMITER = "~";
Skp.msg = "";  // 用于接收ruby发来的临时数据
Skp.LOG_ENABLE = false;


/**
 * 发送ruby操作和数据
 * @param command
 * @param params 是个数组
 */
Skp.send = function(command,params){
    if(params == null){
        params = [];
    }
    Skp.log("skp:"+command + Skp.PAYLOAD_DELIMITER +params.join(Skp.PAYLOAD_PARAMS_DELIMITER));
    //window.location = "skp:skp_js_to_ruby@"+command + Skp.PAYLOAD_DELIMITER +params.join(Skp.PAYLOAD_PARAMS_DELIMITER);
    //sketchup.say(command + Skp.PAYLOAD_DELIMITER +params.join(Skp.PAYLOAD_PARAMS_DELIMITER));
    sketchup.call(command + Skp.PAYLOAD_DELIMITER +params.join(Skp.PAYLOAD_PARAMS_DELIMITER), {
      onCompleted: function() {
        //console.log('Ruby side done.');
      }
    });
}


/**
 * 接收ruby操作和数据
 * @param response
 */
Skp.receive = function(response){
    if(Skp.LOG_ENABLE){
        Skp.log("command:"+response.command + "<br>params:" +JSON.stringify(response.params));
    }
    switch(response.command){
        case 'model_svg': {UI.model_svg(response.params);break;}
        case 'space_parameter_result': {UI.space_parameter_result(response.params);break;}
        case 'space_parameter_error': {UI.space_parameter_error(response.params);break;}
        case 'model_page_status': {UI.model_page_status(response.params);break;}
        case 'model_page_error': {window.alert(response.params.message);break;}
        case 'weather_import_status': {
            UI.weatherImportBusy = !!response.params.running;
            $('#selectCity').prop('disabled', UI.weatherImportBusy);
            break;
        }
        case 'weather_error': {
            if (response.params.station_id) {
                UI.settings.selectCity = response.params.station_id;
                $('#selectCity').val(response.params.station_id);
            }
            window.alert(response.params.message);
            break;
        }
        case "main_analysis_status": {UI.main_analysis_status(response.params);break;}
        case "daylight_status": {UI.daylight_status(response.params);break;}
        case "daylight_result": {UI.daylight_result(response.params);break;}
        case "daylight_error": {UI.daylight_error(response.params);break;}
        case "main_analysis_error": {UI.main_analysis_error(response.params);break;}
        case "main_analysis_result" :{UI.show_main_analysis_result(response.params);break;}
        case "optmize_energy":{UI.update_optimize_energy_result(response.params);break;}
        case "params_analysis_result": {UI.update_params_analysis_result(response.params); break;}
        case "params_multi_goal_analysis_result": {UI.update_multi_goal_params_analysis_result(response.params); break;}
        case "update_model_data":{UI.update_model_data(response.params);break;}
        case "update_daylight_webgl" :{UI.update_daylight_webgl(response.params);break;}
        case "load_weather_stations_data" : {UI.load_weather_stations_data(response.params);break;}
        case "update_weather_chart" : {UI.update_weather_chart(response.params);break;}
        case "update_analysis_history": {UI.update_analysis_history(response.params);break;}
        case "reset_ui":  {UI.reset_ui(response.params);break;}
        case "show_tab": {Skp.send("show",[]);break;}
        case "geometry": {
            UI.update_geometry_info(response.params);break;
        }
        case "model":{
            alert(response.params);
            UI.update_geometry_info(response.params.geometry);
            break;
        }
        default: break;
    }
}

Skp.receive_weather_data = function(data){
    alert("Skp.receive_weather_data")
    alert($("#long_msg").html());
    alert(data);
}


/**
* 日志记录，供界面端调试
**/
Skp.log = function(message){
    if(Skp.LOG_ENABLE){
        $("#serverLog").css("visibility","visible");
        $("#serverLog").append(message + "<br>");
    }
}
