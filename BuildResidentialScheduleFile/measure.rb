# frozen_string_literal: true

# see the URL below for information on how to write OpenStudio measures
# http://nrel.github.io/OpenStudio-user-documentation/reference/measure_writing_guide/

require 'openstudio'
require 'pathname'
require 'oga'
require_relative 'resources/schedules'
require_relative '../HPXMLtoOpenStudio/resources/constants'
require_relative '../HPXMLtoOpenStudio/resources/geometry'
require_relative '../HPXMLtoOpenStudio/resources/hpxml'
require_relative '../HPXMLtoOpenStudio/resources/lighting'
require_relative '../HPXMLtoOpenStudio/resources/meta_measure'
require_relative '../HPXMLtoOpenStudio/resources/schedules'
require_relative '../HPXMLtoOpenStudio/resources/xmlhelper'

# start the measure
class BuildResidentialScheduleFile < OpenStudio::Measure::ModelMeasure
  # human readable name
  def name
    return 'Schedule File Builder'
  end

  # human readable description
  def description
    return 'Builds a residential schedule file.'
  end

  # human readable description of modeling approach
  def modeler_description
    return "Generates CSV schedule(s) at the specified file path(s), and inserts the CSV schedule file path(s) into the output HPXML file (or overwrites it if one already exists). Occupancy schedules corresponding to 'smooth' are average (e.g., Building America). Occupancy schedules corresponding to 'stochastic' are generated using time-inhomogeneous Markov chains derived from American Time Use Survey data, and supplemented with sampling duration and power level from NEEA RBSA data as well as DHW draw duration and flow rate from Aquacraft/AWWA data."
  end

  # define the arguments that the user will input
  def arguments(model)
    args = OpenStudio::Measure::OSArgumentVector.new

    arg = OpenStudio::Measure::OSArgument.makeStringArgument('hpxml_path', true)
    arg.setDisplayName('HPXML File Path')
    arg.setDescription('Absolute/relative path of the HPXML file.')
    args << arg

    schedules_type_choices = OpenStudio::StringVector.new
    schedules_type_choices << 'smooth'
    schedules_type_choices << 'stochastic'

    arg = OpenStudio::Measure::OSArgument.makeChoiceArgument('schedules_type', schedules_type_choices, true)
    arg.setDisplayName('Occupancy Schedules: Type')
    arg.setDescription('The type of occupant-related schedules to use.')
    arg.setDefaultValue('smooth')
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument('schedules_vacancy_period', false)
    arg.setDisplayName('Occupancy Schedules: Vacancy Period')
    arg.setDescription('Specifies the vacancy period. Enter a date like "Dec 15 - Jan 15".')
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeIntegerArgument('schedules_random_seed', false)
    arg.setDisplayName('Occupancy Schedules: Random Seed')
    arg.setUnits('#')
    arg.setDescription("This numeric field is the seed for the random number generator. Only applies if the schedules type is 'stochastic'.")
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument('output_csv_path', true)
    arg.setDisplayName('Occupancy Schedules: Output CSV Path')
    arg.setDescription('Absolute/relative path of the csv file containing user-specified occupancy schedules. Relative paths are relative to the HPXML output path.')
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument('water_heater_scheduled_setpoint_path', false)
    arg.setDisplayName('Water Heater Schedules: Scheduled Setpoint Path')
    arg.setDescription("Absolute/relative path of the csv file containing the water heater setpoint schedule. Setpoint should be defined (in F) for every hour. Applies only to #{HPXML::WaterHeaterTypeStorage} and #{HPXML::WaterHeaterTypeHeatPump}.")
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument('water_heater_scheduled_operating_mode_path', false)
    arg.setDisplayName('Water Heater Schedules: Scheduled Operating Mode Path')
    arg.setDescription("Absolute/relative path of the csv file containing the water heater operating mode schedule. Valid values are 0 (standard) and 1 (heat pump only) and must be specified for every hour. Applies only to #{HPXML::WaterHeaterTypeHeatPump}.")
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument('water_heater_output_csv_path', false)
    arg.setDisplayName('Water Heater Schedules: Output CSV Path')
    arg.setDescription('Absolute/relative path of the csv file containing water heater schedules. Relative paths are relative to the HPXML output path.')
    args << arg

    arg = OpenStudio::Measure::OSArgument.makeStringArgument('hpxml_output_path', true)
    arg.setDisplayName('HPXML Output File Path')
    arg.setDescription('Absolute/relative output path of the HPXML file. This HPXML file will include the output CSV path(s).')
    args << arg

    return args
  end

  # define what happens when the measure is run
  def run(model, runner, user_arguments)
    super(model, runner, user_arguments)

    # use the built-in error checking
    if !runner.validateUserArguments(arguments(model), user_arguments)
      return false
    end

    # assign the user inputs to variables
    args = get_argument_values(runner, arguments(model), user_arguments)
    args = Hash[args.collect { |k, v| [k.to_sym, v] }]

    hpxml_path = args[:hpxml_path]
    unless (Pathname.new hpxml_path).absolute?
      hpxml_path = File.expand_path(File.join(File.dirname(__FILE__), hpxml_path))
    end
    unless File.exist?(hpxml_path) && hpxml_path.downcase.end_with?('.xml')
      fail "'#{hpxml_path}' does not exist or is not an .xml file."
    end

    hpxml_output_path = args[:hpxml_output_path]
    unless (Pathname.new hpxml_output_path).absolute?
      hpxml_output_path = File.expand_path(File.join(File.dirname(__FILE__), hpxml_output_path))
    end
    args[:hpxml_output_path] = hpxml_output_path

    hpxml = HPXML.new(hpxml_path: hpxml_path)

    # create EpwFile object
    epw_path = hpxml.climate_and_risk_zones.weather_station_epw_filepath
    if not File.exist? epw_path
      epw_path = File.join(File.expand_path(File.join(File.dirname(__FILE__), '..', 'weather')), epw_path) # a filename was entered for weather_station_epw_filepath
    end
    if not File.exist? epw_path
      runner.registerError("Could not find EPW file at '#{epw_path}'.")
      return false
    end
    epw_file = OpenStudio::EpwFile.new(epw_path)

    # create the schedules
    success = create_schedules(runner, hpxml, epw_file, args)
    return false if not success

    # modify the hpxml with the schedules path
    doc = XMLHelper.parse_file(hpxml_path)
    extension = XMLHelper.create_elements_as_needed(XMLHelper.get_element(doc, '/HPXML'), ['SoftwareInfo', 'extension'])
    schedules_filepaths = XMLHelper.get_values(extension, 'SchedulesFilePath', :string)
    if !schedules_filepaths.include?(args[:output_csv_path])
      XMLHelper.add_element(extension, 'SchedulesFilePath', args[:output_csv_path], :string)
    end

    # water heater scheduled setpoints and/or operating modes
    if args[:water_heater_scheduled_setpoint_path].is_initialized || args[:water_heater_scheduled_operating_mode_path].is_initialized
      # create the schedules
      success = create_water_heater_schedules(runner, hpxml, args)
      return false if not success

      if !schedules_filepaths.include?(args[:water_heater_output_csv_path].get)
        XMLHelper.add_element(extension, 'SchedulesFilePath', args[:water_heater_output_csv_path].get, :string)
      end
    end

    # write out the modified hpxml
    if (hpxml_path != hpxml_output_path) || !schedules_filepaths.include?(args[:output_csv_path]) || (args[:water_heater_output_csv_path].is_initialized && !schedules_filepaths.include?(args[:water_heater_output_csv_path].get))
      XMLHelper.write_file(doc, hpxml_output_path)
      runner.registerInfo("Wrote file: #{hpxml_output_path}")
    end

    return true
  end

  def create_schedules(runner, hpxml, epw_file, args)
    info_msgs = []

    get_simulation_parameters(hpxml, epw_file, args)
    get_generator_inputs(hpxml, epw_file, args)

    args[:resources_path] = File.join(File.dirname(__FILE__), 'resources')
    schedule_generator = ScheduleGenerator.new(runner: runner, epw_file: epw_file, **args)

    success = schedule_generator.create(args: args)
    return false if not success

    output_csv_path = args[:output_csv_path]
    unless (Pathname.new output_csv_path).absolute?
      output_csv_path = File.expand_path(File.join(File.dirname(args[:hpxml_output_path]), output_csv_path))
    end

    success = schedule_generator.export(schedules_path: output_csv_path)
    return false if not success

    info_msgs << "SimYear=#{args[:sim_year]}"
    info_msgs << "MinutesPerStep=#{args[:minutes_per_step]}"
    info_msgs << "State=#{args[:state]}"
    info_msgs << "RandomSeed=#{args[:random_seed]}" if args[:schedules_random_seed].is_initialized
    info_msgs << "GeometryNumOccupants=#{args[:geometry_num_occupants]}"
    info_msgs << "VacancyPeriod=#{args[:schedules_vacancy_period].get}" if args[:schedules_vacancy_period].is_initialized

    runner.registerInfo("Created #{args[:schedules_type]} schedule with #{info_msgs.join(', ')}")

    return true
  end

  def get_simulation_parameters(hpxml, epw_file, args)
    args[:minutes_per_step] = 60
    if !hpxml.header.timestep.nil?
      args[:minutes_per_step] = hpxml.header.timestep
    end
    args[:steps_in_day] = 24 * 60 / args[:minutes_per_step]
    args[:mkc_ts_per_day] = 96
    args[:mkc_ts_per_hour] = args[:mkc_ts_per_day] / 24

    calendar_year = 2007 # default to TMY
    if !hpxml.header.sim_calendar_year.nil?
      calendar_year = hpxml.header.sim_calendar_year
    end
    if epw_file.startDateActualYear.is_initialized # AMY
      calendar_year = epw_file.startDateActualYear.get
    end
    args[:sim_year] = calendar_year
    args[:sim_start_day] = DateTime.new(args[:sim_year], 1, 1)
    args[:total_days_in_year] = Constants.NumDaysInYear(calendar_year)
  end

  def get_generator_inputs(hpxml, epw_file, args)
    args[:state] = 'CO'
    args[:state] = epw_file.stateProvinceRegion unless epw_file.stateProvinceRegion.empty?
    args[:state] = hpxml.header.state_code unless hpxml.header.state_code.nil?

    args[:random_seed] = args[:schedules_random_seed].get if args[:schedules_random_seed].is_initialized

    if hpxml.building_occupancy.number_of_residents.nil?
      args[:geometry_num_occupants] = Geometry.get_occupancy_default_num(hpxml.building_construction.number_of_bedrooms)
    else
      args[:geometry_num_occupants] = hpxml.building_occupancy.number_of_residents
    end

    if args[:schedules_vacancy_period].is_initialized
      begin_month, begin_day, end_month, end_day = Schedule.parse_date_range(args[:schedules_vacancy_period].get)
      args[:schedules_vacancy_begin_month] = begin_month
      args[:schedules_vacancy_begin_day] = begin_day
      args[:schedules_vacancy_end_month] = end_month
      args[:schedules_vacancy_end_day] = end_day
    end
  end

  def create_water_heater_schedules(runner, hpxml, args)
    rows = []

    if args[:water_heater_scheduled_setpoint_path].is_initialized
      water_heater_scheduled_setpoint_path = args[:water_heater_scheduled_setpoint_path].get
      unless (Pathname.new water_heater_scheduled_setpoint_path).absolute?
        water_heater_scheduled_setpoint_path = File.expand_path(File.join(File.dirname(args[:hpxml_output_path]), water_heater_scheduled_setpoint_path))
      end

      rows << CSV.read(water_heater_scheduled_setpoint_path)
    end

    if args[:water_heater_scheduled_operating_mode_path].is_initialized
      water_heater_scheduled_operating_mode_path = args[:water_heater_scheduled_operating_mode_path].get
      unless (Pathname.new water_heater_scheduled_operating_mode_path).absolute?
        water_heater_scheduled_operating_mode_path = File.expand_path(File.join(File.dirname(args[:hpxml_output_path]), water_heater_scheduled_operating_mode_path))
      end

      rows << CSV.read(water_heater_scheduled_operating_mode_path)
    end

    water_heater_output_csv_path = args[:water_heater_output_csv_path].get
    unless (Pathname.new water_heater_output_csv_path).absolute?
      water_heater_output_csv_path = File.expand_path(File.join(File.dirname(args[:hpxml_output_path]), water_heater_output_csv_path))
    end

    CSV.open(water_heater_output_csv_path, 'w') do |csv|
      rows = rows.transpose
      columns = []
      rows[0].each do |column|
        columns << column[0]
      end
      csv << columns
      rows[1..-1].each do |row|
        csv << row.map { |x| '%.3g' % x }
      end
    end

    runner.registerInfo("Created #{water_heater_output_csv_path}")

    return true
  end
end

# register the measure to be used by the application
BuildResidentialScheduleFile.new.registerWithApplication
