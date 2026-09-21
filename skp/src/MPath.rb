
#模型识别模块
module MPath
    # SketchUp-side files live below <project>/skp. All other paths remain
    # mapped to the shared MoosasPy package root.
    SKP = File.absolute_path(File.dirname(__FILE__)+"/../")+"/"
    BASE = File.absolute_path(File.dirname(__FILE__)+"/../../MoosasPy")+"/"
    SRC = SKP+"src/"
    LIB = BASE+"libs/"
    WEATHER_LIB = LIB + "weather/"
    LEGACY_DATA = BASE+"data/"
    DATA = SKP+"runtime/"
    SCRIPTS = SKP+"scripts/"
    DB = BASE+"db/"
    TEMP = DATA+"tmp/"
    # Keep the embedded interpreter directory separate from the directory
    # inserted into sys.path for `import MoosasPy`.
    PYTHON = File.absolute_path(BASE+"../python")+"/"
    PYTHON_ROOT = File.absolute_path(BASE+"../")+"/"
    PYW_SCRIPT = DATA+"legacy-scripts/"
    EXE_SUFFIX = Gem.win_platform? ? ".exe" : ""
    ENERGY_PUBLIC = LIB+"energy/MoosasEnergyPublic"+EXE_SUFFIX
    ENERGY_RES = LIB+"energy/MoosasEnergyResidential"+EXE_SUFFIX
    UI = SKP + "ui/"
    RAD = LIB + "rad/"
    VENT = LIB + "vent/"
    WEATHER = DB + "weather/"
    SKY = DB + "cum_sky/"

    def self.python_path(path)
        path.to_s.gsub("\\", "/")
    end
end
