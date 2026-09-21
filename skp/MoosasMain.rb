#Ver 0.6.1
#加载脚本
SOURCE = File.dirname(__FILE__)+"/src"
SUFFIX = "rb"

begin
	require "sketchup"
    if Sketchup.os_language == 'zh-CN'
        $language = 'Chinese'
    else
        $language = 'English'
    end
    #$language = 'Chinese'
    #通用全局变量和函数方法
    Sketchup.require("#{SOURCE}/MoosasConstant.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasUtils.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasMeta.#{SUFFIX}")
  Sketchup.require("#{SOURCE}/MPath.#{SUFFIX}")
    
    #基础数据模块：天空模型、气象数据、标准
    Sketchup.require("#{SOURCE}/MoosasSky.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasSolar.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasWeather.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasStandard.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasMap.#{SUFFIX}")
    
    #建模模块：城市建模、单体模型、网格生成函数、模型识别
     Sketchup.require("#{SOURCE}/MoosasUrban.#{SUFFIX}")
     Sketchup.require("#{SOURCE}/MoosasModel.#{SUFFIX}")
     Sketchup.require("#{SOURCE}/MoosasGrid.#{SUFFIX}")
     # RDF.rb is vendored under skp/src and loaded lazily by MoosasRdf.
     # No gem is installed into SketchUp's Ruby environment.
     Sketchup.require("#{SOURCE}/MoosasRdf.#{SUFFIX}")
     Sketchup.require("#{SOURCE}/MMR.#{SUFFIX}")
     Sketchup.require("#{SOURCE}/MoosasSurfaceAnalysis.#{SUFFIX}")
    
    #性能分析模块：能耗、采光、辐射、日照、综合分析
    Sketchup.require("#{SOURCE}/MoosasEnergy.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasDayligt.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasRadiance.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasSunhour.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasVent.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasFoam.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasAnalysis.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasIDF.#{SUFFIX}")
    
    #反向优化设计模块：遗传算法、NSGA2算法、性能算子、形体参数化函数、优化控制器
    Sketchup.require("#{SOURCE}/MoosasGA.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasNSGA2.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasPerformanceEvaluator.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasShapeGenerator.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasOptimizer.#{SUFFIX}")
    
    #可视化界面模块：控制面板、命令菜单、渲染器
    Sketchup.require("#{SOURCE}/MoosasWebDialog.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasUI.#{SUFFIX}")
    Sketchup.require("#{SOURCE}/MoosasRender.#{SUFFIX}")

    #临时项目
    Sketchup.require("#{SOURCE}/MoosasNanji.#{SUFFIX}")
	#Dir.glob("#{SOURCE}/*.{rb,rbs,rbe}") { |file|
	#	Sketchup.require(file)
	#}
rescue Exception => e
	if defined?(e.backtrace)
      	error_backtrace = e.backtrace.join("\n                            ")
      	format_error = "error: message='#{e.inspect}', backtrace='#{error_backtrace}'"
      	log_line = Time.now.asctime+"\t"+format_error+"\n"
    else
    	log_line = Time.now.asctime+"\t error: "+e+"\n"
    end
    p log_line
    # MoosasUtils may be the file that failed to load, so never let the
    # diagnostic handler raise a second NameError and hide the real cause.
    p e.full_message if e.respond_to?(:full_message)
end

#进行初始化工作
module MoosasMain

	def self.init_plugin
		Sketchup.send_action "showRubyPanel:"
		
		p "MOOSAS Ver 0.8.2 Initialization....."
        
		
		MoosasWeather.load_data
        MoosasStandard.load_building_template
		MoosasUI.create_menus
		MoosasUI.create_contexual_menus
        MoosasUI.create_toolbars
	rescue => e
		if defined?(MoosasUtils)
			MoosasUtils.rescue_log(e)
		else
			p e.full_message if e.respond_to?(:full_message)
		end
	end

end

MoosasMain.init_plugin
