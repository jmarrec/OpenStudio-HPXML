# Add classes or functions here than can be used across a variety of our python classes and modules.
require_relative "constants"
require_relative "util"
require_relative "weather"
require_relative "geometry"
require_relative "schedules"
require_relative "unit_conversions"
require_relative "psychrometrics"

class Waterheater
  def self.apply_tank(model, runner, space, fuel_type, cap, vol, ef,
                      re, t_set, oncycle_p, offcycle_p, ec_adj, nbeds, dhw_map, sys_id)

    # Validate inputs
    if vol <= 0
      runner.registerError("Storage tank volume must be greater than 0.")
      return false
    end
    if ef >= 1 or ef <= 0
      runner.registerError("Rated energy factor must be greater than 0 and less than 1.")
      return false
    end
    if t_set <= 0 or t_set >= 212
      runner.registerError("Hot water temperature must be greater than 0 and less than 212.")
      return false
    end
    if cap <= 0
      runner.registerError("Nominal capacity must be greater than 0.")
      return false
    end
    if fuel_type == Constants.FuelTypeElectric
      re = 0.98 # recovery efficiency set by fiat
      oncycle_p = 0
      offcycle_p = 0
    else
      if re < 0 or re > 1
        runner.registerError("Recovery efficiency must be at least 0 and at most 1.")
        return false
      end
      if oncycle_p < 0
        runner.registerError("Forced draft fan power must be greater than 0.")
        return false
      end
      if offcycle_p < 0
        runner.registerError("Parasitic electricity power must be greater than 0.")
        return false
      end
    end

    runner.registerInfo("A new plant loop for DHW will be added to the model")
    runner.registerInitialCondition("No water heater model currently exists")
    loop = create_new_loop(model, Constants.PlantLoopDomesticWater, t_set, Constants.WaterHeaterTypeTank)
    dhw_map[sys_id] << loop

    if loop.components(OpenStudio::Model::PumpVariableSpeed::iddObjectType).empty?
      new_pump = create_new_pump(model)
      new_pump.addToNode(loop.supplyInletNode)
    end

    if loop.supplyOutletNode.setpointManagers.empty?
      new_manager = create_new_schedule_manager(t_set, model, Constants.WaterHeaterTypeTank)
      new_manager.addToNode(loop.supplyOutletNode)
    end

    if space.nil? # Located outside
      water_heater_tz = nil
    else
      water_heater_tz = space.thermalZone.get
    end

    new_heater = create_new_heater(Constants.ObjectNameWaterHeater, cap, fuel_type, vol, ef, re, t_set, water_heater_tz, oncycle_p, offcycle_p, ec_adj, Constants.WaterHeaterTypeTank, 0, nbeds, model, runner)
    dhw_map[sys_id] << new_heater

    storage_tank = get_shw_storage_tank(model)

    if storage_tank.nil?
      loop.addSupplyBranchForComponent(new_heater)
    else
      storage_tank.setHeater1SetpointTemperatureSchedule(new_heater.setpointTemperatureSchedule.get)
      storage_tank.setHeater2SetpointTemperatureSchedule(new_heater.setpointTemperatureSchedule.get)
      new_heater.addToNode(storage_tank.supplyOutletModelObject.get.to_Node.get)
    end

    return true
  end

  def self.apply_tankless(model, runner, space, fuel_type, cap, ef,
                          cd, t_set, oncycle_p, offcycle_p, ec_adj, nbeds, dhw_map, sys_id)

    # Validate inputs
    if ef > 1 or ef <= 0
      runner.registerError("Rated energy factor must be greater than 0 and less than or equal to 1.")
      return false
    end
    if t_set <= 0 or t_set >= 212
      runner.registerError("Hot water temperature must be greater than 0 and less than 212.")
      return false
    end
    if cap <= 0
      runner.registerError("Nominal capacity must be greater than 0.")
      return false
    end
    if cd < 0 or cd > 1
      runner.registerError("Cycling derate must be at least 0 and at most 1.")
      return false
    end
    if fuel_type == Constants.FuelTypeElectric
      oncycle_p = 0
      offcycle_p = 0
    else
      if oncycle_p < 0
        runner.registerError("Forced draft fan power must be greater than 0.")
        return false
      end
      if offcycle_p < 0
        runner.registerError("Parasitic electricity power must be greater than 0.")
        return false
      end
    end

    runner.registerInfo("A new plant loop for DHW will be added to the model")
    runner.registerInitialCondition("No water heater model currently exists")
    loop = Waterheater.create_new_loop(model, Constants.PlantLoopDomesticWater, t_set, Constants.WaterHeaterTypeTankless)
    dhw_map[sys_id] << loop

    if loop.components(OpenStudio::Model::PumpVariableSpeed::iddObjectType).empty?
      new_pump = create_new_pump(model)
      new_pump.addToNode(loop.supplyInletNode)
    end

    if loop.supplyOutletNode.setpointManagers.empty?
      new_manager = create_new_schedule_manager(t_set, model, Constants.WaterHeaterTypeTankless)
      new_manager.addToNode(loop.supplyOutletNode)
    end

    if space.nil? # Located outside
      water_heater_tz = nil
    else
      water_heater_tz = space.thermalZone.get
    end

    new_heater = create_new_heater(Constants.ObjectNameWaterHeater, cap, fuel_type, 1, ef, 0, t_set, water_heater_tz, oncycle_p, offcycle_p, ec_adj, Constants.WaterHeaterTypeTankless, cd, nbeds, model, runner)
    dhw_map[sys_id] << new_heater

    storage_tank = get_shw_storage_tank(model)

    if storage_tank.nil?
      loop.addSupplyBranchForComponent(new_heater)
    else
      storage_tank.setHeater1SetpointTemperatureSchedule(new_heater.setpointTemperatureSchedule.get)
      storage_tank.setHeater2SetpointTemperatureSchedule(new_heater.setpointTemperatureSchedule.get)
      new_heater.addToNode(storage_tank.supplyOutletModelObject.get.to_Node.get)
    end

    return true
  end

  def self.apply_heatpump(model, runner, space, weather, t_set, vol, ef,
                          ec_adj, nbeds, dhw_map, sys_id)

    # FIXME: Use ec_adj

    # Hard coded values for things that wouldn't be captured by hpxml
    int_factor = 1.0 # unitless
    temp_depress = 0.0 # F
    ducting = "none"

    # Based on Ecotope lab testing of most recent AO Smith HPWHs (series HPTU)
    if vol <= 58
      tank_ua = 3.6 # Btu/h-R
    elsif vol <= 73
      tank_ua = 4.0 # Btu/h-R
    else
      tank_ua = 4.7 # Btu/h-R
    end

    e_cap = 4.5 # kW
    min_temp = 42.0 # F
    max_temp = 120.0 # F
    cap = 0.5 # kW
    shr = 0.88 # unitless
    airflow_rate = 181.0 # cfm
    fan_power = 0.0462 # FIXME
    parasitics = 3.0 # W

    # Validate inputs
    if vol <= 0.0
      runner.registerError("Storage tank volume must be greater than 0.")
      return false
    end
    if t_set <= 0.0 or t_set >= 212.0
      runner.registerError("Hot water temperature must be greater than 0 and less than 212.")
      return false
    end
    if e_cap < 0.0
      runner.registerError("Element capacity must be greater than 0.")
      return false
    end
    if min_temp >= 80.0
      runner.registerError("Minimum temperature will prevent HPWH from running, double check inputs.")
      return false
    end
    if max_temp <= 0.0
      runner.registerError("Maximum temperature will prevent HPWH from running, double check inputs.")
      return false
    end
    if cap <= 0.0
      runner.registerError("Rated capacity must be greater than 0.")
      return false
    end
    if shr < 0.0 or shr > 1.0
      runner.registerError("Rated sensible heat ratio must be between 0 and 1.")
      return false
    end
    if airflow_rate <= 0.0
      runner.registerError("Airflow rate must be greater than 0.")
      return false
    end
    if fan_power <= 0.0
      runner.registerError("Fan power must be greater than 0.")
      return false
    end
    if parasitics < 0.0
      runner.registerError("Parasitics must be greater than 0.")
      return false
    end
    if tank_ua <= 0.0
      runner.registerError("Tank UA must be greater than 0.")
      return false
    end
    if int_factor < 0.0 or int_factor > 1.0
      runner.registerError("Interaction factor must be between 0 and 1.")
      return false
    end
    if temp_depress < 0.0
      runner.registerError("Temperature depression must be greater than 0.")
      return false
    end

    # Calculate the COP based on EF
    uef = (0.60522 + ef) / 1.2101
    cop = 1.174536058 * uef # Based on simulation of the UEF test procedure at varying COPs

    obj_name_hpwh = Constants.ObjectNameWaterHeater

    alt = weather.header.Altitude
    if space.nil? # Located outside
      water_heater_tz = nil
    else
      water_heater_tz = space.thermalZone.get
    end

    runner.registerInfo("A new plant loop for DHW will be added to the model")
    runner.registerInitialCondition("There is no existing water heater")
    loop = create_new_loop(model, Constants.PlantLoopDomesticWater, t_set, Constants.WaterHeaterTypeHeatPump)
    dhw_map[sys_id] << loop

    new_pump = create_new_pump(model)
    new_pump.addToNode(loop.supplyInletNode)

    new_manager = create_new_schedule_manager(t_set, model, Constants.WaterHeaterTypeHeatPump)
    new_manager.addToNode(loop.supplyOutletNode)

    # Calculate some geometry parameters for UA, the location of sensors and heat sources in the tank

    h_tank = 0.0188 * vol + 0.0935 # Linear relationship that gets GE height at 50 gal and AO Smith height at 80 gal
    v_actual = 0.9 * vol
    pi = Math::PI
    r_tank = (UnitConversions.convert(v_actual, "gal", "m^3") / (pi * h_tank))**0.5
    a_tank = 2 * pi * r_tank * (r_tank + h_tank)
    u_tank = (5.678 * tank_ua) / UnitConversions.convert(a_tank, "m^2", "ft^2")

    h_UE = (1 - (3.5 / 12)) * h_tank # in the 3rd node of the tank (counting from top)
    h_LE = (1 - (9.5 / 12)) * h_tank # in the 10th node of the tank (counting from top)
    h_condtop = (1 - (5.5 / 12)) * h_tank # in the 6th node of the tank (counting from top)
    h_condbot = 0.01 # bottom node
    h_hpctrl_up = (1 - (2.5 / 12)) * h_tank # in the 3rd node of the tank
    h_hpctrl_low = (1 - (8.5 / 12)) * h_tank # in the 9th node of the tank

    # Calculate an altitude adjusted rated evaporator wetbulb temperature
    rated_ewb_F = 56.4
    rated_edb_F = 67.5
    rated_ewb = UnitConversions.convert(rated_ewb_F, "F", "C")
    rated_edb = UnitConversions.convert(rated_edb_F, "F", "C")
    w_rated = Psychrometrics.w_fT_Twb_P(rated_edb_F, rated_ewb_F, 14.7)
    dp_rated = Psychrometrics.Tdp_fP_w(14.7, w_rated)
    p_atm = Psychrometrics.Pstd_fZ(alt)
    w_adj = Psychrometrics.w_fT_Twb_P(dp_rated, dp_rated, p_atm)
    twb_adj = Psychrometrics.Twb_fT_w_P(rated_edb_F, w_adj, p_atm)

    # Add in schedules for Tamb, RHamb, and the compressor
    hpwh_tamb = OpenStudio::Model::ScheduleConstant.new(model)
    hpwh_tamb.setName("#{obj_name_hpwh} Tamb act")
    hpwh_tamb.setValue(23)

    hpwh_rhamb = OpenStudio::Model::ScheduleConstant.new(model)
    hpwh_rhamb.setName("#{obj_name_hpwh} RHamb act")
    hpwh_rhamb.setValue(0.5)

    if ducting == Constants.VentTypeSupply or ducting == Constants.VentTypeBalanced
      hpwh_tamb2 = OpenStudio::Model::ScheduleConstant.new(model)
      hpwh_tamb2.setName("#{obj_name_hpwh} Tamb act2")
      hpwh_tamb2.setValue(23)
    end

    tset_C = UnitConversions.convert(t_set, "F", "C").to_f.round(2)
    hp_setpoint = OpenStudio::Model::ScheduleConstant.new(model)
    hp_setpoint.setName("#{obj_name_hpwh} WaterHeaterHPSchedule")
    hp_setpoint.setValue(tset_C)

    hpwh_bottom_element_sp = OpenStudio::Model::ScheduleConstant.new(model)
    hpwh_bottom_element_sp.setName("#{obj_name_hpwh} BottomElementSetpoint")

    hpwh_top_element_sp = OpenStudio::Model::ScheduleConstant.new(model)
    hpwh_top_element_sp.setName("#{obj_name_hpwh} TopElementSetpoint")

    hpwh_bottom_element_sp.setValue(-60)
    sp = (tset_C - 9.0001).round(4)
    hpwh_top_element_sp.setValue(sp)

    # WaterHeater:HeatPump:WrappedCondenser
    hpwh = OpenStudio::Model::WaterHeaterHeatPumpWrappedCondenser.new(model)
    hpwh.setName("#{obj_name_hpwh} hpwh")
    hpwh.setCompressorSetpointTemperatureSchedule(hp_setpoint)
    hpwh.setDeadBandTemperatureDifference(3.89)
    hpwh.setCondenserBottomLocation(h_condbot)
    hpwh.setCondenserTopLocation(h_condtop)
    hpwh.setEvaporatorAirFlowRate(UnitConversions.convert(airflow_rate, "ft^3/min", "m^3/s"))
    hpwh.setInletAirConfiguration("Schedule")
    hpwh.setInletAirTemperatureSchedule(hpwh_tamb)
    hpwh.setInletAirHumiditySchedule(hpwh_rhamb)
    hpwh.setMinimumInletAirTemperatureforCompressorOperation(UnitConversions.convert(min_temp, "F", "C"))
    hpwh.setMaximumInletAirTemperatureforCompressorOperation(UnitConversions.convert(max_temp, "F", "C"))
    hpwh.setCompressorLocation("Schedule")
    hpwh.setCompressorAmbientTemperatureSchedule(hpwh_tamb)
    hpwh.setFanPlacement("DrawThrough")
    hpwh.setOnCycleParasiticElectricLoad(0)
    hpwh.setOffCycleParasiticElectricLoad(0)
    hpwh.setParasiticHeatRejectionLocation("Outdoors")
    hpwh.setTankElementControlLogic("MutuallyExclusive")
    hpwh.setControlSensor1HeightInStratifiedTank(h_hpctrl_up)
    hpwh.setControlSensor1Weight(0.75)
    hpwh.setControlSensor2HeightInStratifiedTank(h_hpctrl_low)

    # Curves
    hpwh_cap = OpenStudio::Model::CurveBiquadratic.new(model)
    hpwh_cap.setName("HPWH-Cap-fT")
    hpwh_cap.setCoefficient1Constant(0.563)
    hpwh_cap.setCoefficient2x(0.0437)
    hpwh_cap.setCoefficient3xPOW2(0.000039)
    hpwh_cap.setCoefficient4y(0.0055)
    hpwh_cap.setCoefficient5yPOW2(-0.000148)
    hpwh_cap.setCoefficient6xTIMESY(-0.000145)
    hpwh_cap.setMinimumValueofx(0)
    hpwh_cap.setMaximumValueofx(100)
    hpwh_cap.setMinimumValueofy(0)
    hpwh_cap.setMaximumValueofy(100)

    hpwh_cop = OpenStudio::Model::CurveBiquadratic.new(model)
    hpwh_cop.setName("HPWH-COP-fT")
    hpwh_cop.setCoefficient1Constant(1.1332)
    hpwh_cop.setCoefficient2x(0.063)
    hpwh_cop.setCoefficient3xPOW2(-0.0000979)
    hpwh_cop.setCoefficient4y(-0.00972)
    hpwh_cop.setCoefficient5yPOW2(-0.0000214)
    hpwh_cop.setCoefficient6xTIMESY(-0.000686)
    hpwh_cop.setMinimumValueofx(0)
    hpwh_cop.setMaximumValueofx(100)
    hpwh_cop.setMinimumValueofy(0)
    hpwh_cop.setMaximumValueofy(100)

    # Coil:WaterHeating:AirToWaterHeatPump:Wrapped
    coil = hpwh.dXCoil.to_CoilWaterHeatingAirToWaterHeatPumpWrapped.get
    coil.setName("#{obj_name_hpwh} coil")
    coil.setRatedHeatingCapacity(UnitConversions.convert(cap, "kW", "W") * cop)
    coil.setRatedCOP(cop)
    coil.setRatedSensibleHeatRatio(shr)
    coil.setRatedEvaporatorInletAirDryBulbTemperature(rated_edb)
    coil.setRatedEvaporatorInletAirWetBulbTemperature(UnitConversions.convert(twb_adj, "F", "C"))
    coil.setRatedCondenserWaterTemperature(48.89)
    coil.setRatedEvaporatorAirFlowRate(UnitConversions.convert(airflow_rate, "ft^3/min", "m^3/s"))
    coil.setEvaporatorFanPowerIncludedinRatedCOP(true)
    coil.setEvaporatorAirTemperatureTypeforCurveObjects("WetBulbTemperature")
    coil.setHeatingCapacityFunctionofTemperatureCurve(hpwh_cap)
    coil.setHeatingCOPFunctionofTemperatureCurve(hpwh_cop)
    coil.setMaximumAmbientTemperatureforCrankcaseHeaterOperation(0)
    dhw_map[sys_id] << coil

    # WaterHeater:Stratified
    tank = hpwh.tank.to_WaterHeaterStratified.get
    tank.setName("#{obj_name_hpwh} tank")
    tank.setEndUseSubcategory("Domestic Hot Water")
    tank.setTankVolume(UnitConversions.convert(v_actual, "gal", "m^3"))
    tank.setTankHeight(h_tank)
    tank.setMaximumTemperatureLimit(90)
    tank.setHeaterPriorityControl("MasterSlave")
    tank.setHeater1SetpointTemperatureSchedule(hpwh_top_element_sp) # Overwritten later by EMS
    tank.setHeater1Capacity(UnitConversions.convert(e_cap, "kW", "W"))
    tank.setHeater1Height(h_UE)
    tank.setHeater1DeadbandTemperatureDifference(18.5)
    tank.setHeater2SetpointTemperatureSchedule(hpwh_bottom_element_sp)
    tank.setHeater2Capacity(UnitConversions.convert(e_cap, "kW", "W"))
    tank.setHeater2Height(h_LE)
    tank.setHeater2DeadbandTemperatureDifference(3.89)
    tank.setHeaterFuelType("Electricity")
    tank.setHeaterThermalEfficiency(1)
    tank.setOffCycleParasiticFuelConsumptionRate(parasitics)
    tank.setOffCycleParasiticFuelType("Electricity")
    tank.setOnCycleParasiticFuelConsumptionRate(parasitics)
    tank.setOnCycleParasiticFuelType("Electricity")
    tank.setAmbientTemperatureIndicator("Schedule")
    tank.setUniformSkinLossCoefficientperUnitAreatoAmbientTemperature(u_tank)
    if ducting == Constants.VentTypeSupply or ducting == Constants.VentTypeBalanced
      tank.setAmbientTemperatureSchedule(hpwh_tamb2)
    else
      tank.setAmbientTemperatureSchedule(hpwh_tamb)
    end
    tank.setNumberofNodes(12)
    tank.setAdditionalDestratificationConductivity(0)
    tank.setNode1AdditionalLossCoefficient(0)
    tank.setNode2AdditionalLossCoefficient(0)
    tank.setNode3AdditionalLossCoefficient(0)
    tank.setNode4AdditionalLossCoefficient(0)
    tank.setNode5AdditionalLossCoefficient(0)
    tank.setNode6AdditionalLossCoefficient(0)
    tank.setNode7AdditionalLossCoefficient(0)
    tank.setNode8AdditionalLossCoefficient(0)
    tank.setNode9AdditionalLossCoefficient(0)
    tank.setNode10AdditionalLossCoefficient(0)
    tank.setNode11AdditionalLossCoefficient(0)
    tank.setNode12AdditionalLossCoefficient(0)
    tank.setUseSideDesignFlowRate((UnitConversions.convert(v_actual, "gal", "m^3")) / 60.1)
    tank.setSourceSideDesignFlowRate(0)
    tank.setSourceSideFlowControlMode("")
    tank.setSourceSideInletHeight(0)
    tank.setSourceSideOutletHeight(0)
    dhw_map[sys_id] << tank

    # Fan:OnOff
    fan = hpwh.fan.to_FanOnOff.get
    fan.setName("#{obj_name_hpwh} fan")
    fan.setFanEfficiency(65 / fan_power * UnitConversions.convert(1, "ft^3/min", "m^3/s"))
    fan.setPressureRise(65)
    fan.setMaximumFlowRate(UnitConversions.convert(airflow_rate, "ft^3/min", "m^3/s"))
    fan.setMotorEfficiency(1.0)
    fan.setMotorInAirstreamFraction(1.0)
    fan.setEndUseSubcategory("Domestic Hot Water")

    # Add in EMS program for HPWH interaction with the living space & ambient air temperature depression
    if int_factor != 1 and ducting != "none"
      runner.registerWarning("Interaction factor must be 1 when ducting a HPWH. The input interaction factor value will be ignored and a value of 1 will be used instead.")
      int_factor = 1
    end

    if not space.nil? # If not located outside
      # Add in other equipment objects for sensible/latent gains
      hpwh_sens_def = OpenStudio::Model::OtherEquipmentDefinition.new(model)
      hpwh_sens_def.setName("#{obj_name_hpwh} sens")
      hpwh_sens = OpenStudio::Model::OtherEquipment.new(hpwh_sens_def)
      hpwh_sens.setName(hpwh_sens_def.name.to_s)
      hpwh_sens.setSpace(space)
      hpwh_sens_def.setDesignLevel(0)
      hpwh_sens_def.setFractionRadiant(0)
      hpwh_sens_def.setFractionLatent(0)
      hpwh_sens_def.setFractionLost(0)
      hpwh_sens.setSchedule(model.alwaysOnDiscreteSchedule)

      hpwh_lat_def = OpenStudio::Model::OtherEquipmentDefinition.new(model)
      hpwh_lat_def.setName("#{obj_name_hpwh} lat")
      hpwh_lat = OpenStudio::Model::OtherEquipment.new(hpwh_lat_def)
      hpwh_lat.setName(hpwh_lat_def.name.to_s)
      hpwh_lat.setSpace(space)
      hpwh_lat_def.setDesignLevel(0)
      hpwh_lat_def.setFractionRadiant(0)
      hpwh_lat_def.setFractionLatent(1)
      hpwh_lat_def.setFractionLost(0)
      hpwh_lat.setSchedule(model.alwaysOnDiscreteSchedule)
    end

    # If ducted to outside, get outdoor air T & RH and add a separate actuator for the space temperature for tank losses
    if ducting == Constants.VentTypeSupply or ducting == Constants.VentTypeBalanced

      tout_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Zone Outdoor Air Drybulb Temperature")
      tout_sensor.setName("#{obj_name_hpwh} Tout")
      tout_sensor.setKeyName(living_zone.name.to_s)

      sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Zone Outdoor Air Relative Humidity")
      sensor.setName("#{obj_name_hpwh} RHout")
      sensor.setKeyName(living_zone.name.to_s)

      hpwh_tamb2 = OpenStudio::Model::ScheduleConstant.new(model)
      hpwh_tamb2.setName("#{obj_name_hpwh} Tamb act2")
      hpwh_tamb2.setValue(23)

      tamb_act2_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(hpwh_tamb2, "Schedule:Constant", "Schedule Value")
      tamb_act2_actuator.setName("#{obj_name_hpwh} Tamb act2")

    end

    # EMS Sensors: Space Temperature & RH, HP sens and latent loads, tank losses, fan power
    if water_heater_tz.nil? # Located outside
      amb_temp_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Site Outdoor Air Drybulb Temperature")
      amb_temp_sensor.setName("#{obj_name_hpwh} amb temp")
      amb_temp_sensor.setKeyName("Environment")

      amb_rh_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Site Outdoor Air Relative Humidity")
      amb_rh_sensor.setName("#{obj_name_hpwh} amb rh")
      amb_rh_sensor.setKeyName("Environment")
    else
      amb_temp_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Zone Mean Air Temperature")
      amb_temp_sensor.setName("#{obj_name_hpwh} amb temp")
      amb_temp_sensor.setKeyName(water_heater_tz.name.to_s)

      amb_rh_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Zone Air Relative Humidity")
      amb_rh_sensor.setName("#{obj_name_hpwh} amb rh")
      amb_rh_sensor.setKeyName(water_heater_tz.name.to_s)
    end

    tl_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Water Heater Heat Loss Rate")
    tl_sensor.setName("#{obj_name_hpwh} tl")
    tl_sensor.setKeyName("#{obj_name_hpwh} tank")

    sens_cool_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Cooling Coil Sensible Cooling Rate")
    sens_cool_sensor.setName("#{obj_name_hpwh} sens cool")
    sens_cool_sensor.setKeyName("#{obj_name_hpwh} coil")

    lat_cool_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Cooling Coil Latent Cooling Rate")
    lat_cool_sensor.setName("#{obj_name_hpwh} lat cool")
    lat_cool_sensor.setKeyName("#{obj_name_hpwh} coil")

    fan_power_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Fan Electric Power")
    fan_power_sensor.setName("#{obj_name_hpwh} fan pwr")
    fan_power_sensor.setKeyName("#{obj_name_hpwh} fan")

    # EMS Actuators: Inlet T & RH, sensible and latent gains to the space
    tamb_act_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(hpwh_tamb, "Schedule:Constant", "Schedule Value")
    tamb_act_actuator.setName("#{obj_name_hpwh} Tamb act")

    rhamb_act_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(hpwh_rhamb, "Schedule:Constant", "Schedule Value")
    rhamb_act_actuator.setName("#{obj_name_hpwh} RHamb act")

    if not space.nil?
      sens_act_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(hpwh_sens, "OtherEquipment", "Power Level")
      sens_act_actuator.setName("#{hpwh_sens.name} act")

      lat_act_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(hpwh_lat, "OtherEquipment", "Power Level")
      lat_act_actuator.setName("#{hpwh_lat.name} act")
    end

    on_off_trend_var = OpenStudio::Model::EnergyManagementSystemTrendVariable.new(model, "#{obj_name_hpwh} sens cool".gsub(" ", "_"))
    on_off_trend_var.setName("#{obj_name_hpwh} on off")
    on_off_trend_var.setNumberOfTimestepsToBeLogged(2)

    # Additional sensors if supply or exhaust to calculate the load on the space from the HPWH
    if ducting == Constants.VentTypeSupply or ducting == Constants.VentTypeExhaust

      if water_heater_tz.nil?
        runner.registerError("Water heater cannot be located outside and ducted.")
        return false
      end

      amb_w_sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "Zone Mean Air Humidity Ratio")
      amb_w_sensor.setName("#{obj_name_hpwh} amb w")
      amb_w_sensor.setKeyName(water_heater_tz)

      sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "System Node Pressure")
      sensor.setName("#{obj_name_hpwh} amb p")
      sensor.setKeyName(water_heater_tz)

      sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "System Node Temperature")
      sensor.setName("#{obj_name_hpwh} tair out")
      sensor.setKeyName(water_heater_tz)

      sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "System Node Humidity Ratio")
      sensor.setName("#{obj_name_hpwh} wair out")
      sensor.setKeyName(water_heater_tz)

      sensor = OpenStudio::Model::EnergyManagementSystemSensor.new(model, "System Node Current Density Volume Flow Rate")
      sensor.setName("#{obj_name_hpwh} v air")

    end

    temp_depress_c = temp_depress / 1.8 # don't use convert because it's a delta
    timestep_minutes = (60 / model.getTimestep.numberOfTimestepsPerHour).to_i
    # EMS Program for ducting
    hpwh_ducting_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
    hpwh_ducting_program.setName("#{obj_name_hpwh} InletAir")
    if not water_heater_tz.nil? and not (Geometry.is_conditioned_basement(water_heater_tz) or Geometry.is_living(water_heater_tz)) and temp_depress_c > 0
      runner.registerWarning("Confined space HPWH installations are typically used to represent installations in locations like a utility closet. Utility closets installations are typically only done in conditioned spaces.")
    end
    if temp_depress_c > 0 and ducting == "none"
      hpwh_ducting_program.addLine("Set HPWH_last = (@TrendValue #{on_off_trend_var.name} 1)")
      hpwh_ducting_program.addLine("Set HPWH_now = #{on_off_trend_var.name}")
      hpwh_ducting_program.addLine("Set num = (@Ln 2)")
      hpwh_ducting_program.addLine("If (HPWH_last == 0) && (HPWH_now<>0)") # HPWH just turned on
      hpwh_ducting_program.addLine("Set HPWHOn = 0")
      hpwh_ducting_program.addLine("Set exp = -(HPWHOn / 9.4) * num")
      hpwh_ducting_program.addLine("Set exponent = (@Exp exp)")
      hpwh_ducting_program.addLine("Set T_dep = (#{temp_depress_c} * exponent) - #{temp_depress_c}")
      hpwh_ducting_program.addLine("Set HPWHOn = HPWHOn + #{timestep_minutes}")
      hpwh_ducting_program.addLine("ElseIf (HPWH_last <> 0) && (HPWH_now<>0)") # HPWH has been running for more than 1 timestep
      hpwh_ducting_program.addLine("Set exp = -(HPWHOn / 9.4) * num")
      hpwh_ducting_program.addLine("Set exponent = (@Exp exp)")
      hpwh_ducting_program.addLine("Set T_dep = (#{temp_depress_c} * exponent) - #{temp_depress_c}")
      hpwh_ducting_program.addLine("Set HPWHOn = HPWHOn + #{timestep_minutes}")
      hpwh_ducting_program.addLine("Else")
      hpwh_ducting_program.addLine("If (Hour == 0) && (DayOfYear == 1)")
      hpwh_ducting_program.addLine("Set HPWHOn = 0") # Assume HPWH starts off for initial conditions
      hpwh_ducting_program.addLine("EndIF")
      hpwh_ducting_program.addLine("Set HPWHOn = HPWHOn - #{timestep_minutes}")
      hpwh_ducting_program.addLine("If HPWHOn < 0")
      hpwh_ducting_program.addLine("Set HPWHOn = 0")
      hpwh_ducting_program.addLine("EndIf")
      hpwh_ducting_program.addLine("Set exp = -(HPWHOn / 9.4) * num")
      hpwh_ducting_program.addLine("Set exponent = (@Exp exp)")
      hpwh_ducting_program.addLine("Set T_dep = (#{temp_depress_c} * exponent) - #{temp_depress_c}")
      hpwh_ducting_program.addLine("EndIf")
      hpwh_ducting_program.addLine("Set T_hpwh_inlet = #{amb_temp_sensor.name} + T_dep")
    else
      if ducting == Constants.VentTypeBalanced or ducting == Constants.VentTypeSupply
        hpwh_ducting_program.addLine("Set T_hpwh_inlet = HPWH_out_temp")
      else
        hpwh_ducting_program.addLine("Set T_hpwh_inlet = #{amb_temp_sensor.name}")
      end
    end
    if not space.nil? # If not located outside
      # Sensible/latent heat gain to the space
      if ducting == "none"
        hpwh_ducting_program.addLine("Set #{tamb_act_actuator.name} = T_hpwh_inlet")
        hpwh_ducting_program.addLine("Set #{rhamb_act_actuator.name} = #{amb_rh_sensor.name}/100")
        hpwh_ducting_program.addLine("Set temp1=(#{tl_sensor.name}*#{int_factor})+#{fan_power_sensor.name}*#{int_factor}")
        hpwh_ducting_program.addLine("Set #{sens_act_actuator.name} = 0-(#{sens_cool_sensor.name}*#{int_factor})-temp1")
        hpwh_ducting_program.addLine("Set #{lat_act_actuator.name} = 0 - #{lat_cool_sensor.name} * #{int_factor}")
      elsif ducting == Constants.VentTypeBalanced
        hpwh_ducting_program.addLine("Set #{tamb_act_actuator.name} = T_hpwh_inlet")
        hpwh_ducting_program.addLine("Set #{tamb_act2_actuator.name} = #{amb_temp_sensor.name}")
        hpwh_ducting_program.addLine("Set #{rhamb_act_actuator.name} = HPWH_out_rh/100")
        hpwh_ducting_program.addLine("Set #{sens_act_actuator.name} = 0 - #{tl_sensor.name}")
        hpwh_ducting_program.addLine("Set #{lat_act_actuator.name} = 0")
      elsif ducting == Constants.VentTypeSupply
        hpwh_ducting_program.addLine("Set rho = (@RhoAirFnPbTdbW HPWH_amb_P HPWHTair_out HPWHWair_out)")
        hpwh_ducting_program.addLine("Set cp = (@CpAirFnWTdb HPWHWair_out HPWHTair_out)")
        hpwh_ducting_program.addLine("Set h = (@HFnTdbW HPWHTair_out HPWHWair_out)")
        hpwh_ducting_program.addLine("Set HPWH_sens_gain = rho*cp*(HPWHTair_out-#{amb_temp_sensor.name})*V_airHPWH")
        hpwh_ducting_program.addLine("Set HPWH_lat_gain = h*rho*(HPWHWair_out-#{amb_w_sensor.name})*V_airHPWH")
        hpwh_ducting_program.addLine("Set #{tamb_act_actuator.name} = T_hpwh_inlet")
        hpwh_ducting_program.addLine("Set #{tamb_act2_actuator.name} = #{amb_temp_sensor.name}")
        hpwh_ducting_program.addLine("Set #{rhamb_act_actuator.name} = HPWH_out_rh/100")
        hpwh_ducting_program.addLine("Set #{sens_act_actuator.name} = HPWH_sens_gain - #{tl_sensor.name}")
        hpwh_ducting_program.addLine("Set #{lat_act_actuator.name} = HPWH_lat_gain")
      elsif ducting == Constants.VentTypeExhaust
        hpwh_ducting_program.addLine("Set rho = (@RhoAirFnPbTdbW HPWH_amb_P HPWHTair_out HPWHWair_out)")
        hpwh_ducting_program.addLine("Set cp = (@CpAirFnWTdb HPWHWair_out HPWHTair_out)")
        hpwh_ducting_program.addLine("Set h = (@HFnTdbW HPWHTair_out HPWHWair_out)")
        hpwh_ducting_program.addLine("Set HPWH_sens_gain = rho*cp*(#{tout_sensor.name}-#{amb_temp_sensor.name})*V_airHPWH")
        hpwh_ducting_program.addLine("Set HPWH_lat_gain = h*rho*(Wout-#{amb_w_sensor.name})*V_airHPWH")
        hpwh_ducting_program.addLine("Set #{tamb_act_actuator.name} = T_hpwh_inlet")
        hpwh_ducting_program.addLine("Set #{rhamb_act_actuator.name} = #{amb_rh_sensor.name}/100")
        hpwh_ducting_program.addLine("Set #{sens_act_actuator.name} = HPWH_sens_gain - #{tl_sensor.name}")
        hpwh_ducting_program.addLine("Set #{lat_act_actuator.name} = HPWH_lat_gain")
      end
    end

    leschedoverride_actuator = OpenStudio::Model::EnergyManagementSystemActuator.new(hpwh_bottom_element_sp, "Schedule:Constant", "Schedule Value")
    leschedoverride_actuator.setName("#{obj_name_hpwh} LESchedOverride")

    # EMS for the HPWH control logic
    # Lower element is enabled if the ambient air temperature prevents the HP from running

    hpwh_ctrl_program = OpenStudio::Model::EnergyManagementSystemProgram.new(model)
    hpwh_ctrl_program.setName("#{obj_name_hpwh} Control")
    if ducting == Constants.VentTypeSupply or ducting == Constants.VentTypeBalanced
      hpwh_ctrl_program.addLine("If (HPWH_out_temp < #{UnitConversions.convert(min_temp, "F", "C")}) || (HPWH_out_temp > #{UnitConversions.convert(max_temp, "F", "C")})")
    else
      hpwh_ctrl_program.addLine("If (#{amb_temp_sensor.name}<#{UnitConversions.convert(min_temp, "F", "C").round(2)}) || (#{amb_temp_sensor.name}>#{UnitConversions.convert(max_temp, "F", "C").round(2)})")
    end
    hpwh_ctrl_program.addLine("Set #{leschedoverride_actuator.name} = #{tset_C}")
    hpwh_ctrl_program.addLine("Else")
    hpwh_ctrl_program.addLine("Set #{leschedoverride_actuator.name} = 0")
    hpwh_ctrl_program.addLine("EndIf")

    # ProgramCallingManagers
    program_calling_manager = OpenStudio::Model::EnergyManagementSystemProgramCallingManager.new(model)
    program_calling_manager.setName("#{obj_name_hpwh} ProgramManager")
    program_calling_manager.setCallingPoint("InsideHVACSystemIterationLoop")
    program_calling_manager.addProgram(hpwh_ctrl_program)
    program_calling_manager.addProgram(hpwh_ducting_program)

    storage_tank = get_shw_storage_tank(model)

    if storage_tank.nil?
      loop.addSupplyBranchForComponent(tank)
    else
      storage_tank.setHeater1SetpointTemperatureSchedule(tank.heater1SetpointTemperatureSchedule)
      storage_tank.setHeater2SetpointTemperatureSchedule(tank.heater2SetpointTemperatureSchedule)
      tank.addToNode(storage_tank.supplyOutletModelObject.get.to_Node.get)
    end

    return true
  end

  def self.get_location_hierarchy(ba_cz_name)
    if [Constants.BAZoneHotDry, Constants.BAZoneHotHumid].include? ba_cz_name
      return [Constants.SpaceTypeGarage,
              Constants.SpaceTypeLiving,
              Constants.SpaceTypeConditionedBasement,
              Constants.SpaceTypeUnventedCrawl,
              Constants.SpaceTypeVentedCrawl,
              Constants.SpaceTypeUnventedAttic,
              Constants.SpaceTypeVentedAttic]

    elsif [Constants.BAZoneMarine, Constants.BAZoneMixedHumid, Constants.BAZoneMixedDry, Constants.BAZoneCold, Constants.BAZoneVeryCold, Constants.BAZoneSubarctic].include? ba_cz_name
      return [Constants.SpaceTypeConditionedBasement,
              Constants.SpaceTypeUnconditionedBasement,
              Constants.SpaceTypeLiving,
              Constants.SpaceTypeUnventedCrawl,
              Constants.SpaceTypeVentedCrawl,
              Constants.SpaceTypeUnventedAttic,
              Constants.SpaceTypeVentedAttic]
    elsif ba_cz_name.nil?
      return [Constants.SpaceTypeConditionedBasement,
              Constants.SpaceTypeUnconditionedBasement,
              Constants.SpaceTypeGarage,
              Constants.SpaceTypeLiving]
    end
  end

  def self.calc_water_heater_capacity(fuel, num_beds, num_baths = nil)
    # Calculate the capacity of the water heater based on the fuel type and number of bedrooms and bathrooms in a home
    # returns the capacity in kBtu/hr

    if num_baths.nil?
      num_baths = get_default_num_bathrooms(num_beds)
    end

    if fuel != Constants.FuelTypeElectric
      if num_beds <= 3
        input_power = 36
      elsif num_beds == 4
        if num_baths <= 2.5
          input_power = 36
        else
          input_power = 38
        end
      elsif num_beds == 5
        input_power = 47
      else
        input_power = 50
      end
      return input_power
    else
      if num_beds == 1
        input_power = UnitConversions.convert(2.5, "kW", "kBtu/hr")
      elsif num_beds == 2
        if num_baths <= 1.5
          input_power = UnitConversions.convert(3.5, "kW", "kBtu/hr")
        else
          input_power = UnitConversions.convert(4.5, "kW", "kBtu/hr")
        end
      elsif num_beds == 3
        if num_baths <= 1.5
          input_power = UnitConversions.convert(4.5, "kW", "kBtu/hr")
        else
          input_power = UnitConversions.convert(5.5, "kW", "kBtu/hr")
        end
      else
        input_power = UnitConversions.convert(5.5, "kW", "kBtu/hr")
      end
      return input_power
    end
  end

  def self.calc_ef_from_uef(uef, type, fuel_type)
    # Interpretation on Water Heater UEF
    if fuel_type == Constants.FuelTypeElectric
      if type == Constants.WaterHeaterTypeTank
        return [2.4029 * uef - 1.2844, 0.96].min
      elsif type == Constants.WaterHeaterTypeTankless
        return uef
      elsif type == Constants.WaterHeaterTypeHeatPump
        return 1.2101 * uef - 0.6052
      end
    else # Fuel
      if type == Constants.WaterHeaterTypeTank
        return 0.9066 * uef + 0.0711
      elsif type == Constants.WaterHeaterTypeTankless
        return uef
      end
    end
    return nil
  end

  def self.get_default_num_bathrooms(num_beds)
    # From https://www.sansomeandgeorge.co.uk/news-updates/what-is-the-ideal-ratio-of-bathrooms-to-bedrooms.html
    # "According to 70% of estate agents, a property should have two bathrooms for every three bedrooms..."
    num_baths = 2.0 / 3.0 * num_beds
  end

  def self.get_default_hot_water_temperature(eri_version)
    if eri_version.include? "A"
      return 125.0
    end

    return 120.0
  end

  def self.get_tankless_cycling_derate()
    return 0.08
  end

  private

  def self.get_shw_storage_tank(model)
    model.getPlantLoops.each do |plant_loop|
      next unless plant_loop.name.to_s == Constants.PlantLoopSolarHotWater

      (plant_loop.supplyComponents + plant_loop.demandComponents).each do |component|
        if component.to_WaterHeaterStratified.is_initialized
          return component.to_WaterHeaterStratified.get
        end
      end
    end
    return nil
  end

  def self.deadband(wh_type)
    if wh_type == Constants.WaterHeaterTypeTank
      return 2.0 # deg-C
    else
      return 0.0 # deg-C
    end
  end

  def self.calc_actual_tankvol(vol, fuel, wh_type)
    # Convert the nominal tank volume to an actual volume
    if wh_type == Constants.WaterHeaterTypeTankless
      act_vol = 1 # gal
    else
      if fuel == Constants.FuelTypeElectric
        act_vol = 0.9 * vol
      else
        act_vol = 0.95 * vol
      end
    end
    return act_vol
  end

  def self.calc_tank_UA(vol, fuel, ef, re, pow, wh_type, cyc_derate)
    # Calculates the U value, UA of the tank and conversion efficiency (eta_c)
    # based on the Energy Factor and recovery efficiency of the tank
    # Source: Burch and Erickson 2004 - http://www.nrel.gov/docs/gen/fy04/36035.pdf
    if wh_type == Constants.WaterHeaterTypeTankless
      eta_c = ef * (1 - cyc_derate)
      ua = 0
      surface_area = 1
    else
      pi = Math::PI
      volume_drawn = 64.3 # gal/day
      density = 8.2938 # lb/gal
      draw_mass = volume_drawn * density # lb
      cp = 1.0007 # Btu/lb-F
      t = 135 # F
      t_in = 58 # F
      t_env = 67.5 # F
      q_load = draw_mass * cp * (t - t_in) # Btu/day
      height = 48 # inches
      diameter = 24 * ((vol * 0.1337) / (height / 12 * pi))**0.5 # inches
      surface_area = 2 * pi * (diameter / 12)**2 / 4 + pi * (diameter / 12) * (height / 12) # sqft

      if fuel != Constants.FuelTypeElectric
        ua = (re / ef - 1) / ((t - t_env) * (24 / q_load - 1 / (1000 * (pow) * ef))) # Btu/hr-F
        eta_c = (re + ua * (t - t_env) / (1000 * pow))
      else # is Electric
        ua = q_load * (1 / ef - 1) / ((t - t_env) * 24)
        eta_c = 1.0
      end
    end
    u = ua / surface_area # Btu/hr-ft^2-F
    return u, ua, eta_c
  end

  def self.create_new_pump(model)
    # Add a pump to the new DHW loop
    pump = OpenStudio::Model::PumpVariableSpeed.new(model)
    pump.setRatedFlowRate(0.01)
    pump.setFractionofMotorInefficienciestoFluidStream(0)
    pump.setMotorEfficiency(1)
    pump.setRatedPowerConsumption(0)
    pump.setRatedPumpHead(1)
    pump.setCoefficient1ofthePartLoadPerformanceCurve(0)
    pump.setCoefficient2ofthePartLoadPerformanceCurve(1)
    pump.setCoefficient3ofthePartLoadPerformanceCurve(0)
    pump.setCoefficient4ofthePartLoadPerformanceCurve(0)
    pump.setPumpControlType("Intermittent")
    return pump
  end

  def self.create_new_schedule_manager(t_set, model, wh_type)
    new_schedule = OpenStudio::Model::ScheduleConstant.new(model)
    new_schedule.setName("dhw temp")
    new_schedule.setValue(UnitConversions.convert(t_set, "F", "C") + deadband(wh_type) / 2.0)
    OpenStudio::Model::SetpointManagerScheduled.new(model, new_schedule)
  end

  def self.create_new_heater(name, cap, fuel, vol, ef, re, t_set, thermal_zone, oncycle_p, offcycle_p, ec_adj, wh_type, cyc_derate, nbeds, model, runner)
    new_heater = OpenStudio::Model::WaterHeaterMixed.new(model)
    new_heater.setName(name)
    act_vol = calc_actual_tankvol(vol, fuel, wh_type)
    u, ua, eta_c = calc_tank_UA(act_vol, fuel, ef, re, cap, wh_type, cyc_derate)
    configure_setpoint_schedule(new_heater, t_set, wh_type, model)
    new_heater.setMaximumTemperatureLimit(99.0)
    if wh_type == Constants.WaterHeaterTypeTankless
      new_heater.setHeaterControlType("Modulate")
    else
      new_heater.setHeaterControlType("Cycle")
    end
    new_heater.setDeadbandTemperatureDifference(deadband(wh_type))

    new_heater.setHeaterMinimumCapacity(0.0)
    new_heater.setHeaterMaximumCapacity(UnitConversions.convert(cap, "kBtu/hr", "W"))
    new_heater.setHeaterFuelType(HelperMethods.eplus_fuel_map(fuel))
    new_heater.setHeaterThermalEfficiency(eta_c / ec_adj)
    new_heater.setTankVolume(UnitConversions.convert(act_vol, "gal", "m^3"))

    # Set parasitic power consumption
    if wh_type == Constants.WaterHeaterTypeTankless
      # Tankless WHs are set to "modulate", not "cycle", so they end up
      # effectively always on. Thus, we need to use a weighted-average of
      # on-cycle and off-cycle parasitics.
      # Values used here are based on the average across 10 units originally used when modeling MF buildings
      avg_runtime_frac = [0.0268, 0.0333, 0.0397, 0.0462, 0.0529]
      runtime_frac = avg_runtime_frac[nbeds - 1]
      avg_elec = oncycle_p * runtime_frac + offcycle_p * (1 - runtime_frac)

      new_heater.setOnCycleParasiticFuelConsumptionRate(avg_elec)
      new_heater.setOffCycleParasiticFuelConsumptionRate(avg_elec)
    else
      new_heater.setOnCycleParasiticFuelConsumptionRate(oncycle_p)
      new_heater.setOffCycleParasiticFuelConsumptionRate(offcycle_p)
    end
    new_heater.setOnCycleParasiticFuelType("Electricity")
    new_heater.setOffCycleParasiticFuelType("Electricity")
    new_heater.setOnCycleParasiticHeatFractiontoTank(0)
    new_heater.setOffCycleParasiticHeatFractiontoTank(0)

    # Set fraction of heat loss from tank to ambient (vs out flue)
    # Based on lab testing done by LBNL
    skinlossfrac = 1.0
    if fuel != Constants.FuelTypeElectric and wh_type == Constants.WaterHeaterTypeTank
      if oncycle_p == 0
        skinlossfrac = 0.64
      elsif ef < 0.8
        skinlossfrac = 0.91
      else
        skinlossfrac = 0.96
      end
    end
    new_heater.setOffCycleLossFractiontoThermalZone(skinlossfrac)
    new_heater.setOnCycleLossFractiontoThermalZone(1.0)

    if thermal_zone.nil? # Located outside
      # Set ambient temperature schedule (actuated via EMS to equal the outdoor drybulb temperature)
      new_heater.setAmbientTemperatureIndicator("Outdoors")
    else
      new_heater.setAmbientTemperatureIndicator("ThermalZone")
      new_heater.setAmbientTemperatureThermalZone(thermal_zone)
      if new_heater.ambientTemperatureSchedule.is_initialized
        new_heater.ambientTemperatureSchedule.get.remove
      end
    end
    ua_w_k = UnitConversions.convert(ua, "Btu/(hr*F)", "W/K")
    new_heater.setOnCycleLossCoefficienttoAmbientTemperature(ua_w_k)
    new_heater.setOffCycleLossCoefficienttoAmbientTemperature(ua_w_k)

    return new_heater
  end

  def self.configure_setpoint_schedule(new_heater, t_set, wh_type, model)
    set_temp_c = UnitConversions.convert(t_set, "F", "C") + deadband(wh_type) / 2.0 # Half the deadband to account for E+ deadband
    new_schedule = OpenStudio::Model::ScheduleConstant.new(model)
    new_schedule.setName("WH Setpoint Temp")
    new_schedule.setValue(set_temp_c)
    if new_heater.setpointTemperatureSchedule.is_initialized
      new_heater.setpointTemperatureSchedule.get.remove
    end
    new_heater.setSetpointTemperatureSchedule(new_schedule)
  end

  def self.create_new_loop(model, name, t_set, wh_type)
    # Create a new plant loop for the water heater
    loop = OpenStudio::Model::PlantLoop.new(model)
    loop.setName(name)
    loop.sizingPlant.setDesignLoopExitTemperature(UnitConversions.convert(t_set, "F", "C") + deadband(wh_type) / 2.0)
    loop.sizingPlant.setLoopDesignTemperatureDifference(UnitConversions.convert(10, "R", "K"))
    loop.setPlantLoopVolume(0.003) # ~1 gal
    loop.setMaximumLoopFlowRate(0.01) # This size represents the physical limitations to flow due to losses in the piping system. For BEopt we assume that the pipes are always adequately sized

    bypass_pipe = OpenStudio::Model::PipeAdiabatic.new(model)
    out_pipe = OpenStudio::Model::PipeAdiabatic.new(model)

    loop.addSupplyBranchForComponent(bypass_pipe)
    out_pipe.addToNode(loop.supplyOutletNode)

    return loop
  end

  def self.get_water_heater(model, plant_loop, runner)
    plant_loop.supplyComponents.each do |wh|
      if wh.to_WaterHeaterMixed.is_initialized
        return wh.to_WaterHeaterMixed.get
      elsif wh.to_WaterHeaterStratified.is_initialized
        waterHeater = wh.to_WaterHeaterStratified.get
        # Look for attached HPWH
        model.getWaterHeaterHeatPumpWrappedCondensers.each do |hpwh|
          next if not hpwh.tank.to_WaterHeaterStratified.is_initialized
          next if hpwh.tank.to_WaterHeaterStratified.get != waterHeater

          return hpwh
        end
      end
    end
    runner.registerError("No water heater found; add a residential water heater first.")
    return nil
  end

  def self.get_water_heater_setpoint(model, plant_loop, runner)
    waterHeater = get_water_heater(model, plant_loop, runner)
    if waterHeater.is_a? OpenStudio::Model::WaterHeaterMixed
      if waterHeater.setpointTemperatureSchedule.nil?
        runner.registerError("Water heater found without a setpoint temperature schedule.")
        return nil
      end
      return UnitConversions.convert(waterHeater.setpointTemperatureSchedule.get.to_ScheduleConstant.get.value - waterHeater.deadbandTemperatureDifference / 2.0, "C", "F")
    elsif waterHeater.is_a? OpenStudio::Model::WaterHeaterHeatPumpWrappedCondenser
      if waterHeater.compressorSetpointTemperatureSchedule.nil?
        runner.registerError("Heat pump water heater found without a setpoint temperature schedule.")
        return nil
      end
      return UnitConversions.convert(waterHeater.compressorSetpointTemperatureSchedule.to_ScheduleConstant.get.value, "C", "F")
    end
    return nil
  end

  def self.get_water_heater_setpoint_schedule(model, plant_loop, runner)
    waterHeater = get_water_heater(model, plant_loop, runner)
    if waterHeater.is_a? OpenStudio::Model::WaterHeaterMixed
      if waterHeater.setpointTemperatureSchedule.nil?
        runner.registerError("Water heater found without a setpoint temperature schedule.")
        return nil
      end
      return waterHeater.setpointTemperatureSchedule.get
    elsif waterHeater.is_a? OpenStudio::Model::WaterHeaterHeatPumpWrappedCondenser
      if waterHeater.compressorSetpointTemperatureSchedule.nil?
        runner.registerError("Heat pump water heater found without a setpoint temperature schedule.")
        return nil
      end
      return waterHeater.compressorSetpointTemperatureSchedule
    end
    return nil
  end
end
