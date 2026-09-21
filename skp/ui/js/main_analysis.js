// Versioned Main analysis adapter. Other analysis pages retain their own handlers.
(function () {
    var parts = ['cooling', 'heating', 'lighting', 'equipment'];
    var colors = ['#4285f4', '#ea4335', '#fbbc05', '#78909c'];
    var legacyResult = UI.show_main_analysis_result;
    function message(text) {
        if (!$('#main_analysis_status').length) $('#main_analysis').after('<div id="main_analysis_status" role="status"></div>');
        $('#main_analysis_status').text(text);
    }
    UI.main_analysis_status = function (data) {
        UI.mainRequestId = data.request_id;
        UI.mainBusy = !!data.running;
        $('#main_analysis').prop('disabled', UI.mainBusy);
        var stages = {submitted: '提交中 / Submitting', recognizing: '识别模型 / Recognizing', model: '模型准备 / Preparing model', weather: '气象准备 / Preparing weather', radiation: '辐射模拟 / Radiation', energy: '能耗计算 / Energy', daylight: '采光计算 / Daylight', complete: '', stale: '模型已变化，请重新分析。'};
        if (data.stage !== 'failed') {
            var text = Object.prototype.hasOwnProperty.call(stages, data.stage) ? stages[data.stage] : '';
            message(text);
        }
    };
    UI.main_analysis_error = function (data) {
        UI.mainBusy = false;
        $('#main_analysis').prop('disabled', false);
        if (data.code === 'recognition_required') {
            message('');
            var key = data.request_id + ':' + data.code;
            if (!data.restored && UI.mainAlertKey !== key) {
                UI.mainAlertKey = key;
                window.alert(data.message);
            }
        } else {
            message(data.message);
        }
    };
    function donut(id, values, labels, palette, center) {
        // Fixed regions within the existing 230px card: ring above, 2x2 key below.
        // Annotation keys cannot collide with Plotly's automatic legend/labels.
        var annotations = [{x: .5, y: .67, xref: 'paper', yref: 'paper',
            xanchor: 'center', yanchor: 'middle', text: center, showarrow: false,
            font: {size: 13, color: '#333'}}];
        labels.forEach(function (label, i) {
            annotations.push({x: i % 2 ? .53 : .02, y: i < 2 ? .22 : .08,
                xref: 'paper', yref: 'paper', xanchor: 'left', yanchor: 'middle',
                text: '<span style="color:' + palette[i] + '">■</span> ' + label,
                showarrow: false, font: {size: 11, color: '#555'}});
        });
        Plotly.newPlot(id, [{type: 'pie', hole: .72, sort: false, direction: 'clockwise',
            domain: {x: [0, 1], y: [.34, 1]}, textinfo: 'none', hoverinfo: 'label+value+percent',
            labels: labels, values: values, marker: {colors: palette, line: {color: '#fff', width: 2}}}],
            {width: 230, height: 230, margin: {t: 4, b: 4, l: 4, r: 4}, showlegend: false,
                annotations: annotations, paper_bgcolor: 'rgba(0,0,0,0)'},
            Object.assign({}, UI.defaultPlotlyConfiguration, {displayModeBar: false}));
    }
    function bars(id, rows, labels, unit) {
        Plotly.newPlot(id, parts.map(function (part, i) {
            return {type: 'bar', name: part, x: labels, y: rows.map(function (r) { return r[part]; }), marker: {color: colors[i]}};
        }), {barmode: 'stack', yaxis: {title: unit}, margin: {t: 30}}, UI.defaultPlotlyConfiguration);
    }
    UI.show_main_analysis_result = function (data) {
        if (data.schema_version !== 2) return legacyResult(data);
        UI.mainLastResult = data;
        var energy = data.energy;
        UI.result = UI.result || {};
        UI.result.total_area = data.area_m2;
        UI.result.eui = energy.annual.total;
        $('#total_area').text(data.area_m2.toFixed(1));
        $('#eui_value').text(energy.annual.total.toFixed(2));
        $('#total_energy_value').text((energy.absolute_kwh / 1000).toFixed(2));
        donut('energy_percent', parts.map(function (p) {return energy.annual[p];}),
            ['Cooling', 'Heating', 'Lighting', 'Equipment'], colors, 'kWh/m²·year');
        bars('month_energy_chart', energy.months, energy.months.map(function (m) {return m.month;}), 'kWh/m²');
        bars('space_energy_chart', energy.spaces.map(function (s) {return s.annual;}), energy.spaces.map(function (s) {return s.name;}), 'kWh/m²·年');
        var bins = [0, 0, 0];
        data.daylight.spaces.forEach(function (s) {bins[s.factor_percent < 3 ? 0 : s.factor_percent > 8 ? 2 : 1] += s.area_m2;});
        donut('daylight_percent', bins, ['&lt;3%', '3–8%', '&gt;8%'], ['#90a4ae', '#66bb6a', '#ffca28'],
            data.daylight.area_weighted_mean_percent.toFixed(1) + '%');
        UI.main_analysis_status({request_id: data.request_id, running: false, stage: 'complete'});
    };
    UI.update_analysis_history = function (records) {
        var rows = (records || []).map(function (value, i) {
            var d = typeof value === 'string' ? JSON.parse(value) : value;
            return d.schema_version === 2 ? {name: d.request_id, area: d.area_m2, energy: d.energy.annual} : {
                name: '#' + (i + 1) + '（旧三项口径）', area: Number(d.area), energy: {cooling: Number(d.energy[0]), heating: Number(d.energy[1]), lighting: Number(d.energy[2]), equipment: null, total: Number(d.energy[0]) + Number(d.energy[1]) + Number(d.energy[2])}};
        });
        bars('history_chart', rows.map(function (r) {return r.energy;}), rows.map(function (r) {return r.name;}), 'kWh/m²·年');
        var fields = ['名称', '面积 m²', '总量 kWh/年', '冷', '热', '照明', '设备'];
        var values = rows.map(function (r) {return [r.name, r.area.toFixed(1), (r.area * r.energy.total).toFixed(2)].concat(parts.map(function (p) {return r.energy[p] === null ? '未知' : (r.area * r.energy[p]).toFixed(2);}));});
        Plotly.newPlot('history_table', [{type: 'table', header: {values: fields}, cells: {values: fields.map(function (_, i) {return values.map(function (r) {return r[i];});})}}], {}, UI.defaultPlotlyConfiguration);
    };
    $(function () {Skp.send('main_analysis_state', []);});
}());
