require 'csv'
require 'yaml'
require 'matrix'

class ScheduleGenerator
  def initialize(runner:,
                 model:,
                 weather:,
                 building_id: nil,
                 num_occupants:,
                 vacancy_start_date:,
                 vacancy_end_date:,
                 schedules_path:,
                 **remainder)

    @runner = runner
    @model = model
    @weather = weather
    @building_id = building_id
    @num_occupants = num_occupants
    @vacancy_start_date = vacancy_start_date
    @vacancy_end_date = vacancy_end_date
    @schedules_path = schedules_path
  end

  def get_simulation_parameters
    min_per_step = 1 # FIXME: get min_per_step from hpxml, not model (since it hasn't been set yet)
    if @model.getSimulationControl.timestep.is_initialized
      min_per_step = 60 / @model.getSimulationControl.timestep.get.numberOfTimestepsPerHour
    end
    steps_in_day = 24 * 60 / min_per_step

    mkc_ts_per_day = 96
    mkc_ts_per_hour = mkc_ts_per_day / 24

    @model.getYearDescription.isLeapYear ? total_days_in_year = 366 : total_days_in_year = 365

    return min_per_step, steps_in_day, mkc_ts_per_day, mkc_ts_per_hour, total_days_in_year
  end

  def get_building_id
    if @building_id.nil?
      building_id = @model.getBuilding.additionalProperties.getFeatureAsInteger('Building ID') # this becomes the seed
      if building_id.is_initialized
        building_id = building_id.get
      else
        @runner.registerWarning('Unable to retrieve the Building ID (seed for schedule generator); setting it to 1.')
        building_id = 1
      end
    else
      building_id = @building_id
    end

    return building_id
  end

  def initialize_schedules(num_ts:)
    schedules = {
      'occupants' => Array.new(num_ts, 0.0),
      'cooking_range' => Array.new(num_ts, 0.0),
      'plug_loads' => Array.new(num_ts, 0.0),
      'lighting_interior' => Array.new(num_ts, 0.0),
      'lighting_exterior' => Array.new(num_ts, 0.0),
      'lighting_garage' => Array.new(num_ts, 0.0),
      'lighting_exterior_holiday' => Array.new(num_ts, 0.0),
      'clothes_washer' => Array.new(num_ts, 0.0),
      'clothes_dryer' => Array.new(num_ts, 0.0),
      'dishwasher' => Array.new(num_ts, 0.0),
      'baths' => Array.new(num_ts, 0.0),
      'showers' => Array.new(num_ts, 0.0),
      'sinks' => Array.new(num_ts, 0.0),
      'ceiling_fan' => Array.new(num_ts, 0.0),
      'clothes_dryer_exhaust' => Array.new(num_ts, 0.0),
      'clothes_washer_power' => Array.new(num_ts, 0.0),
      'dishwasher_power' => Array.new(num_ts, 0.0),
      'sleep' => Array.new(num_ts, 0.0),
      'vacancy' => Array.new(num_ts, 0.0)
    }

    return schedules
  end

  def schedules
    return @schedules
  end

  def create
    minutes_per_steps, steps_in_day, mkc_ts_per_day, mkc_ts_per_hour, total_days_in_year = get_simulation_parameters
    building_id = get_building_id

    @schedules = initialize_schedules(num_ts: total_days_in_year * steps_in_day)

    # initialize a random number generator using building_id
    prng = Random.new(building_id)

    # load the schedule configuration file
    schedule_config = YAML.load_file(@schedules_path + '/schedule_config.yml')

    # pre-load the probability distribution csv files for speed
    cluster_size_prob_map = read_activity_cluster_size_probs()
    event_duration_prob_map = read_event_duration_probs()
    activity_duration_prob_map = read_activity_duration_prob()
    appliance_power_dist_map = read_appliance_power_dist()

    all_simulated_values = [] # holds the markov-chain state for each of the seven simulated states for each occupant.
    # States are: 'sleeping', 'shower', 'laundry', 'cooking', 'dishwashing', 'absent', 'nothingAtHome'
    # if num_occupants = 2, period_in_a_year = 35040,  num_of_states = 7, then
    # shape of all_simulated_values is [2, 35040, 7]
    (1..@num_occupants).each do |i|
      occ_type_id = weighted_random(prng, schedule_config['occupancy_types_probability'])
      init_prob_file_weekday = @schedules_path + "/weekday/mkv_chain_initial_prob_cluster_#{occ_type_id}.csv"
      initial_prob_weekday = CSV.read(init_prob_file_weekday)
      initial_prob_weekday = initial_prob_weekday.map { |x| x[0].to_f }
      init_prob_file_weekend = @schedules_path + "/weekend/mkv_chain_initial_prob_cluster_#{occ_type_id}.csv"
      initial_prob_weekend = CSV.read(init_prob_file_weekend)
      initial_prob_weekend = initial_prob_weekend.map { |x| x[0].to_f }

      transition_matrix_file_weekday = @schedules_path + "/weekday/mkv_chain_transition_prob_cluster_#{occ_type_id}.csv"
      transition_matrix_weekday = CSV.read(transition_matrix_file_weekday)
      transition_matrix_weekday = transition_matrix_weekday.map { |x| x.map { |y| y.to_f } }
      transition_matrix_file_weekend = @schedules_path + "/weekend/mkv_chain_transition_prob_cluster_#{occ_type_id}.csv"
      transition_matrix_weekend = CSV.read(transition_matrix_file_weekend)
      transition_matrix_weekend = transition_matrix_weekend.map { |x| x.map { |y| y.to_f } }

      simulated_values = []
      sim_year = @model.getYearDescription.calendarYear.get
      start_day = DateTime.new(sim_year, 1, 1)
      total_days_in_year.times do |day|
        today = start_day + day
        day_of_week = today.wday
        if [0, 6].include?(day_of_week)
          # Weekend
          day_type = 'weekend'
          initial_prob = initial_prob_weekend
          transition_matrix = transition_matrix_weekend
        else
          # weekday
          day_type = 'weekday'
          initial_prob = initial_prob_weekday
          transition_matrix = transition_matrix_weekday
        end
        j = 0
        state_prob = initial_prob # [] shape = 1x7. probability of transitioning to each of the 7 states
        while j < mkc_ts_per_day do
          active_state = weighted_random(prng, state_prob) # Randomly pick the next state
          state_vector = [0] * 7 # there are 7 states
          state_vector[active_state] = 1 # Transition to the new state
          # sample the duration of the state, and skip markov-chain based state transition until the end of the duration
          activity_duration = sample_activity_duration(prng, activity_duration_prob_map, occ_type_id, active_state, day_type, j / 4)
          activity_duration.times do |repeat_activity_count|
            # repeat the same activity for the duration times
            simulated_values << state_vector
            j += 1
            if j >= mkc_ts_per_day then break end # break as soon as we have filled acitivities for the day
          end
          if j >= mkc_ts_per_day then break end # break as soon as we have filled activities for the day

          transition_probs = transition_matrix[(j - 1) * 7...j * 7] # obtain the transition matrix for current timestep
          transition_probs_matrix = Matrix[*transition_probs]
          current_state_vec = Matrix.row_vector(state_vector)
          state_prob = current_state_vec * transition_probs_matrix # Get a new state_probability array
          state_prob = state_prob.to_a[0]
        end
      end
      # Markov-chain transition probabilities is based on ATUS data, and the starting time of day for the data is
      # 4 am. We need to shift everything forward by 16 timesteps to make it midnight-based.
      simulated_values = simulated_values.rotate(-4 * 4) # 4am shifting (4 hours  = 4 * 4 steps of 15 min intervals)
      all_simulated_values << Matrix[*simulated_values]
    end
    # shape of all_simulated_values is [2, 35040, 7] i.e. (num_occupants, period_in_a_year, number_of_states)
    plugload_sch = schedule_config['plugload']
    lighting_sch = schedule_config['lighting']
    ceiling_fan_sch = schedule_config['ceiling_fan']

    monthly_lighting_schedule = schedule_config['lighting']['monthly_multiplier']
    holiday_lighting_schedule = schedule_config['lighting']['holiday_sch']

    sch_option_type = Constants.OptionTypeLightingScheduleCalculated
    interior_lighting_schedule = get_interior_lighting_sch(@model, @runner, @weather, sch_option_type, monthly_lighting_schedule)
    holiday_lighting_schedule = get_holiday_lighting_sch(@model, @runner, holiday_lighting_schedule)

    away_schedule = []
    idle_schedule = []

    # fill in the yearly time_step resolution schedule for plug/lighting and ceiling fan based on weekday/weekend sch
    # # States are: 0='sleeping', 1='shower', 2='laundry', 3='cooking', 4='dishwashing', 5='absent', 6='nothingAtHome'
    sim_year = @model.getYearDescription.calendarYear.get
    start_day = DateTime.new(sim_year, 1, 1)
    total_days_in_year.times do |day|
      today = start_day + day
      month = today.month
      day_of_week = today.wday
      [0, 6].include?(day_of_week) ? is_weekday = false : is_weekday = true
      steps_in_day.times do |step|
        minute = day * 1440 + step * minutes_per_steps
        index_15 = (minute / 15).to_i
        sleep = sum_across_occupants(all_simulated_values, 0, index_15).to_f / @num_occupants
        @schedules['sleep'][day * steps_in_day + step] = sleep
        away_schedule << sum_across_occupants(all_simulated_values, 5, index_15).to_f / @num_occupants
        idle_schedule << sum_across_occupants(all_simulated_values, 6, index_15).to_f / @num_occupants
        active_occupancy_percentage = 1 - (away_schedule[-1] + sleep)
        @schedules['plug_loads'][day * steps_in_day + step] = get_value_from_daily_sch(plugload_sch, month, is_weekday, minute, active_occupancy_percentage)
        @schedules['lighting_interior'][day * steps_in_day + step] = scale_lighting_by_occupancy(interior_lighting_schedule, minute, active_occupancy_percentage)
        @schedules['lighting_exterior'][day * steps_in_day + step] = get_value_from_daily_sch(lighting_sch, month, is_weekday, minute, 1)
        @schedules['lighting_garage'][day * steps_in_day + step] = get_value_from_daily_sch(lighting_sch, month, is_weekday, minute, 1)
        @schedules['lighting_exterior_holiday'][day * steps_in_day + step] = scale_lighting_by_occupancy(holiday_lighting_schedule, minute, 1)
        @schedules['ceiling_fan'][day * steps_in_day + step] = get_value_from_daily_sch(ceiling_fan_sch, month, is_weekday, minute, active_occupancy_percentage)
      end
    end
    @schedules['plug_loads'] = normalize(@schedules['plug_loads'])
    @schedules['lighting_interior'] = normalize(@schedules['lighting_interior'])
    @schedules['lighting_exterior'] = normalize(@schedules['lighting_exterior'])
    @schedules['lighting_garage'] = normalize(@schedules['lighting_garage'])
    @schedules['lighting_exterior_holiday'] = normalize(@schedules['lighting_exterior_holiday'])
    @schedules['ceiling_fan'] = normalize(@schedules['ceiling_fan'])

    # Generate the Sink Schedule
    # 1. Find indexes (minutes) when at least one occupant can have sink event (they aren't sleeping or absent)
    # 2. Determine number of cluster per day
    # 3. Sample flow-rate for the sink
    # 4. For each cluster
    #   a. sample for number_of_events
    #   b. Re-normalize onset probability by removing invalid indexes (invalid = where we already have sink events)
    #   b. Probabilistically determine the start of the first event based on onset probability.
    #   c. For each event in number_of_events
    #      i. Sample the duration
    #      ii. Add the time occupied by event to invalid_index
    #      ii. if more events, offset by fixed wait time and goto c
    #   d. if more cluster, go to 4.
    mins_in_year = 1440 * total_days_in_year
    mkc_steps_in_a_year = total_days_in_year * mkc_ts_per_day
    sink_activtiy_probable_mins = [0] * mkc_steps_in_a_year # 0 indicates sink activity cannot happen at that time
    sink_activity_sch = [0] * 1440 * total_days_in_year
    # mark minutes when at least one occupant is doing nothing at home as possible sink activity time
    # States are: 0='sleeping', 1='shower', 2='laundry', 3='cooking', 4='dishwashing', 5='absent', 6='nothingAtHome'
    mkc_steps_in_a_year.times do |step|
      all_simulated_values.size.times do |i| # across occupants
        # if at least one occupant is not sleeping and not absent from home, then sink event can occur at that time
        if not ((all_simulated_values[i][step, 0] == 1) || (all_simulated_values[i][step, 5] == 1))
          sink_activtiy_probable_mins[step] = 1
        end
      end
    end

    sink_duration_probs = schedule_config['sink']['duration_probability']
    events_per_cluster_probs = schedule_config['sink']['events_per_cluster_probs']
    hourly_onset_prob = schedule_config['sink']['hourly_onset_prob']
    total_clusters = schedule_config['sink']['total_annual_cluster']
    sink_between_event_gap = schedule_config['sink']['between_event_gap']
    cluster_per_day = total_clusters / total_days_in_year
    sink_flow_rate_mean = schedule_config['sink']['flow_rate_mean']
    sink_flow_rate_std = schedule_config['sink']['flow_rate_std']
    sink_flow_rate = gaussian_rand(prng, sink_flow_rate_mean, sink_flow_rate_std, 0.1)
    total_days_in_year.times do |day|
      cluster_per_day.times do |cluster_count|
        todays_probable_steps = sink_activtiy_probable_mins[day * mkc_ts_per_day...((day + 1) * mkc_ts_per_day)]
        todays_probablities = todays_probable_steps.map.with_index { |p, i| p * hourly_onset_prob[i / mkc_ts_per_hour] }
        prob_sum = todays_probablities.reduce(0, :+)
        normalized_probabilities = todays_probablities.map { |p| p * 1 / prob_sum }
        cluster_start_index = weighted_random(prng, normalized_probabilities)
        sink_activtiy_probable_mins[cluster_start_index] = 0 # mark the 15-min interval as unavailable for another sink event
        num_events = weighted_random(prng, events_per_cluster_probs) + 1
        start_min = cluster_start_index * 15
        end_min = (cluster_start_index + 1) * 15
        num_events.times do |event_count|
          duration = weighted_random(prng, sink_duration_probs) + 1
          if start_min + duration > end_min then duration = (end_min - start_min) end
          sink_activity_sch.fill(sink_flow_rate, (day * 1440) + start_min, duration)
          start_min += duration + sink_between_event_gap # Two minutes gap between sink activity
          if start_min >= end_min then break end
        end
      end
    end

    # Generate minute level schedule for shower and bath
    # 1. Identify the shower time slots from the mkc schedule. This corresponds to personal hygiene time
    # For each slot:
    # 2. Determine if the personal hygiene is to be bath/shower using bath_to_shower_ratio probability
    # 3. Sample for the shower and bath flow rate. (These will remain same throughout the year for a given building)
    #    However, the duration of each shower/bath event can be different, so, in 15-minute aggregation, the shower/bath
    #    Water consumption might appear different between different events
    # 4. If it is shower
    #   a. Determine the number of events in the shower cluster (there can be multiple showers)
    #   b. For each event, sample the shower duration
    #   c. Fill in the time period of personal hygiene using that many events of corresponding duration
    #      separated by shower_between_event_gap.
    #      TODO If there is room in the mkc personal hygiene slot, shift uniform randomly
    # 5. If it is bath
    #   a. Sample the bath duration
    #   b. Fill in the mkc personal hygiene slot with the bath duration and flow rate.
    #      TODO If there is room in the mkc personal hygiene slot, shift uniform randomly
    # 6. Repeat process 2-6 for each occupant
    shower_between_event_gap = schedule_config['shower']['between_event_gap']
    shower_flow_rate_mean = schedule_config['shower']['flow_rate_mean']
    shower_flow_rate_std = schedule_config['shower']['flow_rate_std']
    bath_ratio = schedule_config['bath']['bath_to_shower_ratio']
    bath_duration_mean = schedule_config['bath']['duration_mean']
    bath_duration_std = schedule_config['bath']['duration_std']
    bath_flow_rate_mean = schedule_config['bath']['flow_rate_mean']
    bath_flow_rate_std = schedule_config['bath']['flow_rate_std']
    m = 0
    shower_activity_sch = [0] * mins_in_year
    bath_activity_sch = [0] * mins_in_year
    bath_flow_rate = gaussian_rand(prng, bath_flow_rate_mean, bath_flow_rate_std, 0.1)
    shower_flow_rate = gaussian_rand(prng, shower_flow_rate_mean, shower_flow_rate_std, 0.1)
    # States are: 'sleeping','shower','laundry','cooking', 'dishwashing', 'absent', 'nothingAtHome'
    step = 0
    while step < mkc_steps_in_a_year
      # shower_state will be equal to number of occupant taking shower/bath in the given 15-minute mkc interval
      shower_state = sum_across_occupants(all_simulated_values, 1, step)
      step_jump = 1
      if shower_state > 0
        shower_state.to_i.times do |occupant_number|
          r = prng.rand
          if r <= bath_ratio
            # fill in bath for this time
            duration = gaussian_rand(prng, bath_duration_mean, bath_duration_std, 0.1)
            int_duration = duration.ceil
            # since we are rounding duration to integer minute, we compensate by scaling flow rate
            flow_rate = bath_flow_rate * duration / int_duration
            start_min = step * 15
            m = 0
            int_duration.times do
              bath_activity_sch[start_min + m] += flow_rate
              m += 1
              if (start_min + m) >= mins_in_year then break end
            end
            step_jump = [step_jump, 1 + (m / 15)].max # jump additional step if the bath occupies multiple 15-min slots
          else
            # fill in the shower
            num_events = sample_activity_cluster_size(prng, cluster_size_prob_map, 'shower')
            start_min = step * 15
            m = 0
            num_events.times do
              duration = sample_event_duration(prng, event_duration_prob_map, 'shower')
              int_duration = duration.ceil
              flow_rate = shower_flow_rate * duration / int_duration
              # since we are rounding duration to integer minute, we compensate by scaling flow rate
              int_duration.times do
                shower_activity_sch[start_min + m] += flow_rate
                m += 1
                if (start_min + m) >= mins_in_year then break end
              end
              shower_between_event_gap.times do
                # skip the gap between events
                m += 1
                if (start_min + m) >= mins_in_year then break end
              end
              if start_min + m >= mins_in_year then break end
            end
            step_jump = [step_jump, 1 + (m / 15)].max
          end
        end
      end
      step += step_jump
    end

    # Generate minute level schedule for dishwasher and clothes washer
    # 1. Identify the dishwasher/clothes washer time slots from the mkc schedule.
    # 2. Sample for the flow_rate
    # 3. Determine the number of events in the dishwasher/clothes washer cluster
    #    (it's typically composed of multiple water draw events)
    # 4. For each event, sample the event duration
    # 5. Fill in the dishwasher/clothes washer time slot using those water draw events

    dw_flow_rate_mean = schedule_config['dishwasher']['flow_rate_mean']
    dw_flow_rate_std = schedule_config['dishwasher']['flow_rate_std']
    dw_between_event_gap = schedule_config['dishwasher']['between_event_gap']
    dw_activity_sch = [0] * mins_in_year
    m = 0
    dw_flow_rate = gaussian_rand(prng, dw_flow_rate_mean, dw_flow_rate_std, 0)

    # States are: 'sleeping','shower','laundry','cooking', 'dishwashing', 'absent', 'nothingAtHome'
    # Fill in dw_water draw schedule
    step = 0
    while step < mkc_steps_in_a_year
      dish_state = sum_across_occupants(all_simulated_values, 4, step, max_clip = 1)
      step_jump = 1
      if dish_state > 0
        cluster_size = sample_activity_cluster_size(prng, cluster_size_prob_map, 'dishwasher')
        start_minute = step * 15
        m = 0
        cluster_size.times do
          duration = sample_event_duration(prng, event_duration_prob_map, 'dishwasher')
          int_duration = duration.ceil
          flow_rate = dw_flow_rate * duration / int_duration
          int_duration.times do
            dw_activity_sch[start_minute + m] = flow_rate
            m += 1
            if start_minute + m >= mins_in_year then break end
          end
          if start_minute + m >= mins_in_year then break end

          dw_between_event_gap.times do
            m += 1
            if start_minute + m >= mins_in_year then break end
          end
          if start_minute + m >= mins_in_year then break end
        end
        step_jump = [step_jump, 1 + (m / 15)].max
      end
      step += step_jump
    end

    cw_flow_rate_mean = schedule_config['clothes_washer']['flow_rate_mean']
    cw_flow_rate_std = schedule_config['clothes_washer']['flow_rate_std']
    cw_between_event_gap = schedule_config['clothes_washer']['between_event_gap']
    cw_activity_sch = [0] * mins_in_year # this is the clothes_washer water draw schedule
    cw_load_size_probability = schedule_config['clothes_washer']['load_size_probability']
    m = 0
    cw_flow_rate = gaussian_rand(prng, cw_flow_rate_mean, cw_flow_rate_std, 0)
    # States are: 'sleeping','shower','laundry','cooking', 'dishwashing', 'absent', 'nothingAtHome'
    step = 0
    # Fill in clothes washer water draw schedule based on markov-chain state 2 (laundry)
    while step < mkc_steps_in_a_year
      clothes_state = sum_across_occupants(all_simulated_values, 2, step, max_clip = 1)
      step_jump = 1
      if clothes_state > 0
        num_loads = weighted_random(prng, cw_load_size_probability) + 1
        start_minute = step * 15
        m = 0
        num_loads.times do
          cluster_size = sample_activity_cluster_size(prng, cluster_size_prob_map, 'clothes_washer')
          cluster_size.times do
            duration = sample_event_duration(prng, event_duration_prob_map, 'clothes_washer')
            int_duration = duration.ceil
            flow_rate = cw_flow_rate * duration.to_f / int_duration
            int_duration.times do
              cw_activity_sch[start_minute + m] = flow_rate
              m += 1
              if start_minute + m >= mins_in_year then break end
            end
            if start_minute + m >= mins_in_year then break end

            cw_between_event_gap.times do
              # skip the gap between events
              m += 1
              if start_minute + m >= mins_in_year then break end
            end
            if start_minute + m >= mins_in_year then break end
          end
        end
        if start_minute + m >= mins_in_year then break end

        step_jump = [step_jump, 1 + (m / 15)].max
      end
      step += step_jump
    end

    # States are: 'sleeping', 'shower', 'laundry', 'cooking', 'dishwashing', 'absent', 'nothingAtHome'
    # Fill in dishwasher and clothes_washer power draw schedule based on markov-chain
    # This follows similar pattern as filling in water draw events, except we use different set of probability
    # distribution csv files for power level and duration of each event. And there is only one event per mkc slot.
    dw_power_sch = [0] * mins_in_year
    step = 0
    last_state = 0
    while step < mkc_steps_in_a_year
      dish_state = sum_across_occupants(all_simulated_values, 4, step, max_clip = 1)
      step_jump = 1
      if (dish_state > 0) && (last_state == 0) # last_state == 0 prevents consecutive dishwasher power without gap
        duration_15min, avg_power = sample_appliance_duration_power(prng, appliance_power_dist_map, 'dishwasher')
        duration = [duration_15min * 15, mins_in_year - step * 15].min
        dw_power_sch.fill(avg_power, step * 15, duration)
        step_jump = duration_15min
      end
      last_state = dish_state
      step += step_jump
    end

    # Fill in cw and clothes dryer power schedule
    # States are: 'sleeping', 'shower', 'laundry', 'cooking', 'dishwashing', 'absent', 'nothingAtHome'
    cw_power_sch = [0] * mins_in_year
    cd_power_sch = [0] * mins_in_year
    step = 0
    last_state = 0
    while step < mkc_steps_in_a_year
      clothes_state = sum_across_occupants(all_simulated_values, 2, step, max_clip = 1)
      step_jump = 1
      if (clothes_state > 0) && (last_state == 0) # last_state == 0 prevents consecutive washer power without gap
        cw_duration_15min, cw_avg_power = sample_appliance_duration_power(prng, appliance_power_dist_map, 'clothes_washer')
        cd_duration_15min, cd_avg_power = sample_appliance_duration_power(prng, appliance_power_dist_map, 'clothes_dryer')
        cw_duration = [cw_duration_15min * 15, mins_in_year - step * 15].min
        cw_power_sch.fill(cw_avg_power, step * 15, cw_duration)
        cd_start_time = (step * 15 + cw_duration).to_i # clothes dryer starts immediately after washer ends\
        cd_duration = [cd_duration_15min * 15, mins_in_year - cd_start_time].min # cd_duration would be negative if cd_start_time > mins_in_year, and no filling would occur
        cd_power_sch = cd_power_sch.fill(cd_avg_power, cd_start_time, cd_duration)
        step_jump = cw_duration_15min + cd_duration_15min
      end
      last_state = clothes_state
      step += step_jump
    end

    # Fill in cooking power schedule
    # States are: 'sleeping','shower','laundry','cooking', 'dishwashing', 'absent', 'nothingAtHome'
    cooking_power_sch = [0] * mins_in_year
    step = 0
    last_state = 0
    while step < mkc_steps_in_a_year
      cooking_state = sum_across_occupants(all_simulated_values, 3, step, max_clip = 1)
      step_jump = 1
      if (cooking_state > 0) && (last_state == 0) # last_state == 0 prevents consecutive cooking power without gap
        duration_15min, avg_power = sample_appliance_duration_power(prng, appliance_power_dist_map, 'cooking')
        duration = [duration_15min * 15, mins_in_year - step * 15].min
        cooking_power_sch.fill(avg_power, step * 15, duration)
        step_jump = duration_15min
      end
      last_state = cooking_state
      step += step_jump
    end
    offset_range = 30
    random_offset = (prng.rand * 2 * offset_range).to_i - offset_range
    sink_activity_sch = sink_activity_sch.rotate(-4 * 60 + random_offset) # 4 am shifting
    sink_activity_sch = aggregate_array(sink_activity_sch, minutes_per_steps)
    @schedules['sinks'] = sink_activity_sch.map { |flow| flow / Constants.PeakFlowRate }

    random_offset = (prng.rand * 2 * offset_range).to_i - offset_range
    dw_activity_sch = dw_activity_sch.rotate(random_offset)
    dw_activity_sch = aggregate_array(dw_activity_sch, minutes_per_steps)
    @schedules['dishwasher'] = dw_activity_sch.map { |flow| flow / Constants.PeakFlowRate }

    random_offset = (prng.rand * 2 * offset_range).to_i - offset_range
    cw_activity_sch = cw_activity_sch.rotate(random_offset)
    cw_activity_sch = aggregate_array(cw_activity_sch, minutes_per_steps)
    @schedules['clothes_washer'] = cw_activity_sch.map { |flow| flow / Constants.PeakFlowRate }

    random_offset = (prng.rand * 2 * offset_range).to_i - offset_range
    shower_activity_sch = shower_activity_sch.rotate(random_offset)
    shower_activity_sch = aggregate_array(shower_activity_sch, minutes_per_steps)
    @schedules['showers'] = shower_activity_sch.map { |flow| flow / Constants.PeakFlowRate }

    random_offset = (prng.rand * 2 * offset_range).to_i - offset_range
    bath_activity_sch = bath_activity_sch.rotate(random_offset)
    bath_activity_sch = aggregate_array(bath_activity_sch, minutes_per_steps)
    @schedules['baths'] = bath_activity_sch.map { |flow| flow / Constants.PeakFlowRate }

    random_offset = (prng.rand * 2 * offset_range).to_i - offset_range
    cooking_power_sch = cooking_power_sch.rotate(random_offset)
    cooking_power_sch = aggregate_array(cooking_power_sch, minutes_per_steps)
    @schedules['cooking_range'] = cooking_power_sch.map { |power| power / Constants.PeakPower }

    random_offset = (prng.rand * 2 * offset_range).to_i - offset_range
    cw_power_sch = cw_power_sch.rotate(random_offset)
    cw_power_sch = aggregate_array(cw_power_sch, minutes_per_steps)
    @schedules['clothes_washer_power'] = cw_power_sch.map { |power| power / Constants.PeakPower }

    random_offset = (prng.rand * 2 * offset_range).to_i - offset_range
    cd_power_sch = cd_power_sch.rotate(random_offset)
    cd_power_sch = aggregate_array(cd_power_sch, minutes_per_steps)
    @schedules['clothes_dryer'] = cd_power_sch.map { |power| power / Constants.PeakPower }
    @schedules['clothes_dryer_exhaust'] = @schedules['clothes_dryer']

    random_offset = (prng.rand * 2 * offset_range).to_i - offset_range
    dw_power_sch = dw_power_sch.rotate(random_offset)
    dw_power_sch = aggregate_array(dw_power_sch, minutes_per_steps)
    @schedules['dishwasher_power'] = dw_power_sch.map { |power| power / Constants.PeakPower }

    @schedules['occupants'] = away_schedule.map { |i| 1.0 - i }

    success = set_vacancy(min_per_step: minutes_per_steps, sim_year: sim_year)
    return false if not success

    return true
  end

  def set_vacancy(min_per_step:,
                  sim_year:)
    if not ((@vacancy_start_date.downcase == 'na') && (@vacancy_end_date.downcase == 'na'))
      begin
        vacancy_start_date = Time.new(sim_year, OpenStudio::monthOfYear(@vacancy_start_date.split[0]).value, @vacancy_start_date.split[1].to_i)
        vacancy_end_date = Time.new(sim_year, OpenStudio::monthOfYear(@vacancy_end_date.split[0]).value, @vacancy_end_date.split[1].to_i, 24)

        sec_per_step = min_per_step * 60.0
        ts = Time.new(sim_year, 'Jan', 1)
        @schedules['vacancy'].each_with_index do |step, i|
          if vacancy_start_date <= ts && ts <= vacancy_end_date # in the vacancy period
            @schedules['vacancy'][i] = 1.0
          end
          ts += sec_per_step
        end

        @runner.registerInfo("Set vacancy period from #{@vacancy_start_date} tp #{@vacancy_end_date}.")
      rescue
        @runner.registerError('Invalid vacancy date(s) specified.')
      end
    else
      @runner.registerInfo('No vacancy period set.')
    end
    return true
  end

  def aggregate_array(array, group_size)
    new_array_size = array.size / group_size
    new_array = [0] * new_array_size
    new_array_size.times do |j|
      new_array[j] = array[(j * group_size)...(j + 1) * group_size].reduce(0, :+)
    end
    return new_array
  end

  def read_appliance_power_dist()
    activity_names = ['clothes_washer', 'dishwasher', 'clothes_dryer', 'cooking']
    power_dist_map = {}
    activity_names.each do |activity|
      duration_file = @schedules_path + "/#{activity}_power_duration_dist.csv"
      consumption_file = @schedules_path + "/#{activity}_power_consumption_dist.csv"
      duration_vals = CSV.read(duration_file)
      consumption_vals = CSV.read(consumption_file)
      duration_vals = duration_vals.map { |a| a.map { |i| i.to_i } }
      consumption_vals = consumption_vals.map { |a| a[0].to_f }
      power_dist_map[activity] = [duration_vals, consumption_vals]
    end
    return power_dist_map
  end

  def sample_appliance_duration_power(prng, power_dist_map, appliance_name)
    # returns number number of 15-min interval the appliance runs, and the average 15-min power
    duration_vals, consumption_vals = power_dist_map[appliance_name]
    if @consumption_row.nil?
      # initialize and pick the consumption and duration row only the first time
      # checking only consumption_row is sufficient because duration_row always go side by side with consumption row
      @consumption_row = {}
      @duration_row = {}
    end
    if !@consumption_row.has_key?(appliance_name)
      @consumption_row[appliance_name] = (prng.rand * consumption_vals.size).to_i
      @duration_row[appliance_name] = (prng.rand * duration_vals.size).to_i
    end
    power = consumption_vals[@consumption_row[appliance_name]]
    duration = duration_vals[@duration_row[appliance_name]].sample
    return [duration, power]
  end

  def read_activity_cluster_size_probs()
    activity_names = ['clothes_washer', 'dishwasher', 'shower']
    cluster_size_prob_map = {}
    activity_names.each do |activity|
      cluster_size_file = @schedules_path + "/#{activity}_cluster_size_probability.csv"
      cluster_size_probabilities = CSV.read(cluster_size_file)
      cluster_size_probabilities = cluster_size_probabilities.map { |entry| entry[0].to_f }
      cluster_size_prob_map[activity] = cluster_size_probabilities
    end
    return cluster_size_prob_map
  end

  def read_event_duration_probs()
    activity_names = ['clothes_washer', 'dishwasher', 'shower']
    event_duration_probabilites_map = {}
    activity_names.each do |activity|
      duration_file = @schedules_path + "/#{activity}_event_duration_probability.csv"
      duration_probabilities = CSV.read(duration_file)
      durations = duration_probabilities.map { |entry| entry[0].to_f / 60 } # convert to minute
      probabilities = duration_probabilities.map { |entry| entry[1].to_f }
      event_duration_probabilites_map[activity] = [durations, probabilities]
    end
    return event_duration_probabilites_map
  end

  def read_activity_duration_prob()
    cluster_types = ['0', '1', '2', '3']
    day_types = ['weekday', 'weekend']
    time_of_days = ['morning', 'midday', 'evening']
    activity_names = ['shower', 'cooking', 'dishwashing', 'laundry']
    activity_duration_prob_map = {}
    cluster_types.each do |cluster_type|
      day_types.each do |day_type|
        time_of_days.each do |time_of_day|
          activity_names.each do |activity_name|
            duration_file = @schedules_path + "/#{day_type}/duration_probability/"\
                    "cluster_#{cluster_type}_#{activity_name}_#{time_of_day}_duration_probability.csv"
            duration_probabilities = CSV.read(duration_file)
            durations = duration_probabilities.map { |entry| entry[0].to_i }
            probabilities = duration_probabilities.map { |entry| entry[1].to_f }
            activity_duration_prob_map["#{cluster_type}_#{activity_name}_#{day_type}_#{time_of_day}"] = [durations, probabilities]
          end
        end
      end
    end
    return activity_duration_prob_map
  end

  def sample_activity_cluster_size(prng, cluster_size_prob_map, activity_type_name)
    cluster_size_probabilities = cluster_size_prob_map[activity_type_name]
    return weighted_random(prng, cluster_size_probabilities) + 1
  end

  def sample_event_duration(prng, duration_probabilites_map, event_type)
    durations = duration_probabilites_map[event_type][0]
    probabilities = duration_probabilites_map[event_type][1]
    return durations[weighted_random(prng, probabilities)]
  end

  def sample_activity_duration(prng, activity_duration_prob_map, occ_type_id, activity, day_type, hour)
    # States are: 'sleeping','shower','laundry','cooking', 'dishwashing', 'absent', 'nothingAtHome'
    if hour < 8
      time_of_day = 'morning'
    elsif hour < 16
      time_of_day = 'midday'
    else
      time_of_day = 'evening'
    end

    if activity == 1
      activity_name = 'shower'
    elsif activity == 2
      activity_name = 'laundry'
    elsif activity == 3
      activity_name = 'cooking'
    elsif activity == 4
      activity_name = 'dishwashing'
    else
      return 1 # all other activity will span only one mkc step
    end
    durations = activity_duration_prob_map["#{occ_type_id}_#{activity_name}_#{day_type}_#{time_of_day}"][0]
    probabilities = activity_duration_prob_map["#{occ_type_id}_#{activity_name}_#{day_type}_#{time_of_day}"][1]
    return durations[weighted_random(prng, probabilities)]
  end

  def export(output_path:)
    CSV.open(output_path, 'w') do |csv|
      csv << @schedules.keys
      rows = @schedules.values.transpose
      rows.each do |row|
        csv << row
      end
    end
    return true
  end

  def gaussian_rand(prng, mean, std, min = nil, max = nil)
    t = 2 * Math::PI * prng.rand
    r = Math.sqrt(-2 * Math.log(1 - prng.rand))
    scale = std * r
    x = mean + scale * Math.cos(t)
    if (not min.nil?) && (x < min) then x = min end
    if (not max.nil?) && (x > max) then x = max end
    # y = mean + scale * Math.sin(t)
    return x
  end

  def sum_across_occupants(all_simulated_values, activity_index, time_index, max_clip = nil)
    sum = 0
    all_simulated_values.size.times do |i|
      sum += all_simulated_values[i][time_index, activity_index]
    end
    if (not max_clip.nil?) && (sum > max_clip)
      sum = max_clip
    end
    return sum
  end

  def normalize(arr)
    m = arr.max
    arr = arr.map { |a| a / m }
    return arr
  end

  def scale_lighting_by_occupancy(lighting_sch, minute, active_occupant_percentage)
    day_start = minute / 1440
    day_sch = lighting_sch[day_start * 24, 24]
    current_val = lighting_sch[minute / 60]
    return day_sch.min + (current_val - day_sch.min) * active_occupant_percentage
  end

  def get_value_from_daily_sch(daily_sch, month, is_weekday, minute, active_occupant_percentage)
    is_weekday ? sch = daily_sch['weekday_sch'] : sch = daily_sch['weekend_sch']
    full_occupancy_current_val = sch[((minute % 1440) / 60).to_i].to_f * daily_sch['monthly_multiplier'][month - 1].to_f
    return sch.min + (full_occupancy_current_val - sch.min) * active_occupant_percentage
  end

  def weighted_random(prng, weights)
    n = prng.rand
    cum_weights = 0
    weights.each_with_index do |w, index|
      cum_weights += w
      if n <= cum_weights
        return index
      end
    end
    return weights.size - 1 # If the prob weight don't sum to n, return last index
  end

  def get_holiday_lighting_sch(model, runner, holiday_sch)
    holiday_start_day = 332 # November 27
    holiday_end_day = 6 # Jan 6
    @model.getYearDescription.isLeapYear ? total_days_in_year = 366 : total_days_in_year = 365
    sch = [0] * 24 * total_days_in_year
    final_days = total_days_in_year - holiday_start_day + 1
    beginning_days = holiday_end_day
    sch[0...holiday_end_day * 24] = holiday_sch * beginning_days
    sch[(holiday_start_day - 1) * 24..-1] = holiday_sch * final_days
    m = sch.max
    sch = sch.map { |s| s / m }
    return sch
  end

  def get_interior_lighting_sch(model, runner, weather, sch_option_type, monthly_sch)
    lat = weather.header.Latitude
    long = weather.header.Longitude
    tz = weather.header.Timezone
    std_long = -tz * 15
    pi = Math::PI

    # Get number of days in months/year
    year_description = model.getYearDescription
    num_days_in_months = Constants.NumDaysInMonths(year_description.isLeapYear)
    num_days_in_year = Constants.NumDaysInYear(year_description.isLeapYear)

    # Sunrise and sunset hours
    sunrise_hour = []
    sunset_hour = []
    normalized_hourly_lighting = [[1..24], [1..24], [1..24], [1..24], [1..24], [1..24], [1..24], [1..24], [1..24], [1..24], [1..24], [1..24]]
    for month in 0..11
      if lat < 51.49
        m_num = month + 1
        jul_day = m_num * 30 - 15
        if not ((m_num < 4) || (m_num > 10))
          offset = 1
        else
          offset = 0
        end
        declination = 23.45 * Math.sin(0.9863 * (284 + jul_day) * 0.01745329)
        deg_rad = pi / 180
        rad_deg = 1 / deg_rad
        b = (jul_day - 1) * 0.9863
        equation_of_time = (0.01667 * (0.01719 + 0.42815 * Math.cos(deg_rad * b) - 7.35205 * Math.sin(deg_rad * b) - 3.34976 * Math.cos(deg_rad * (2 * b)) - 9.37199 * Math.sin(deg_rad * (2 * b))))
        sunset_hour_angle = rad_deg * Math.acos(-1 * Math.tan(deg_rad * lat) * Math.tan(deg_rad * declination))
        sunrise_hour[month] = offset + (12.0 - 1 * sunset_hour_angle / 15.0) - equation_of_time - (std_long + long) / 15
        sunset_hour[month] = offset + (12.0 + 1 * sunset_hour_angle / 15.0) - equation_of_time - (std_long + long) / 15
      else
        sunrise_hour = [8.125726064, 7.449258072, 6.388688653, 6.232405257, 5.27722936, 4.84705384, 5.127512162, 5.860163988, 6.684378904, 7.521267411, 7.390441945, 8.080667697]
        sunset_hour = [16.22214058, 17.08642353, 17.98324493, 19.83547864, 20.65149672, 21.20662992, 21.12124777, 20.37458274, 19.25834757, 18.08155615, 16.14359164, 15.75571306]
      end
    end

    dec_kws = [0.075, 0.055, 0.040, 0.035, 0.030, 0.025, 0.025, 0.025, 0.025, 0.025, 0.025, 0.030, 0.045, 0.075, 0.130, 0.160, 0.140, 0.100, 0.075, 0.065, 0.060, 0.050, 0.045, 0.045, 0.045, 0.045, 0.045, 0.045, 0.050, 0.060, 0.080, 0.130, 0.190, 0.230, 0.250, 0.260, 0.260, 0.250, 0.240, 0.225, 0.225, 0.220, 0.210, 0.200, 0.180, 0.155, 0.125, 0.100]
    june_kws = [0.060, 0.040, 0.035, 0.025, 0.020, 0.020, 0.020, 0.020, 0.020, 0.020, 0.020, 0.020, 0.020, 0.025, 0.030, 0.030, 0.025, 0.020, 0.015, 0.015, 0.015, 0.015, 0.015, 0.015, 0.015, 0.015, 0.015, 0.015, 0.015, 0.015, 0.015, 0.015, 0.020, 0.020, 0.020, 0.025, 0.025, 0.030, 0.030, 0.035, 0.045, 0.060, 0.085, 0.125, 0.145, 0.130, 0.105, 0.080]
    lighting_seasonal_multiplier =   [1.075, 1.064951905, 1.0375, 1.0, 0.9625, 0.935048095, 0.925, 0.935048095, 0.9625, 1.0, 1.0375, 1.064951905]
    amplConst1 = 0.929707907917098
    sunsetLag1 = 2.45016230615269
    stdDevCons1 = 1.58679810983444
    amplConst2 = 1.1372291802273
    sunsetLag2 = 20.1501965859073
    stdDevCons2 = 2.36567663279954

    monthly_kwh_per_day = []
    wtd_avg_monthly_kwh_per_day = 0
    for monthNum in 1..12
      month = monthNum - 1
      monthHalfHourKWHs = [0]
      for hourNum in 0..9
        monthHalfHourKWHs[hourNum] = june_kws[hourNum]
      end
      for hourNum in 9..17
        hour = (hourNum + 1.0) * 0.5
        monthHalfHourKWHs[hourNum] = (monthHalfHourKWHs[8] - (0.15 / (2 * pi)) * Math.sin((2 * pi) * (hour - 4.5) / 3.5) + (0.15 / 3.5) * (hour - 4.5)) * lighting_seasonal_multiplier[month]
      end
      for hourNum in 17..29
        hour = (hourNum + 1.0) * 0.5
        monthHalfHourKWHs[hourNum] = (monthHalfHourKWHs[16] - (-0.02 / (2 * pi)) * Math.sin((2 * pi) * (hour - 8.5) / 5.5) + (-0.02 / 5.5) * (hour - 8.5)) * lighting_seasonal_multiplier[month]
      end
      for hourNum in 29..45
        hour = (hourNum + 1.0) * 0.5
        monthHalfHourKWHs[hourNum] = (monthHalfHourKWHs[28] + amplConst1 * Math.exp((-1.0 * (hour - (sunset_hour[month] + sunsetLag1))**2) / (2.0 * ((25.5 / ((6.5 - monthNum).abs + 20.0)) * stdDevCons1)**2)) / ((25.5 / ((6.5 - monthNum).abs + 20.0)) * stdDevCons1 * (2.0 * pi)**0.5))
      end
      for hourNum in 45..46
        hour = (hourNum + 1.0) * 0.5
        temp1 = (monthHalfHourKWHs[44] + amplConst1 * Math.exp((-1.0 * (hour - (sunset_hour[month] + sunsetLag1))**2) / (2.0 * ((25.5 / ((6.5 - monthNum).abs + 20.0)) * stdDevCons1)**2)) / ((25.5 / ((6.5 - monthNum).abs + 20.0)) * stdDevCons1 * (2.0 * pi)**0.5))
        temp2 = (0.04 + amplConst2 * Math.exp((-1.0 * (hour - sunsetLag2)**2) / (2.0 * stdDevCons2**2)) / (stdDevCons2 * (2.0 * pi)**0.5))
        if sunsetLag2 < sunset_hour[month] + sunsetLag1
          monthHalfHourKWHs[hourNum] = [temp1, temp2].min
        else
          monthHalfHourKWHs[hourNum] = [temp1, temp2].max
        end
      end
      for hourNum in 46..47
        hour = (hourNum + 1) * 0.5
        monthHalfHourKWHs[hourNum] = (0.04 + amplConst2 * Math.exp((-1.0 * (hour - sunsetLag2)**2) / (2.0 * stdDevCons2**2)) / (stdDevCons2 * (2.0 * pi)**0.5))
      end

      sum_kWh = 0.0
      for timenum in 0..47
        sum_kWh += monthHalfHourKWHs[timenum]
      end
      for hour in 0..23
        ltg_hour = (monthHalfHourKWHs[hour * 2] + monthHalfHourKWHs[hour * 2 + 1]).to_f
        normalized_hourly_lighting[month][hour] = ltg_hour / sum_kWh
        monthly_kwh_per_day[month] = sum_kWh / 2.0
      end
      wtd_avg_monthly_kwh_per_day += monthly_kwh_per_day[month] * num_days_in_months[month] / num_days_in_year
    end

    # Get the seasonal multipliers
    seasonal_multiplier = []
    if sch_option_type == Constants.OptionTypeLightingScheduleCalculated
      for month in 0..11
        seasonal_multiplier[month] = (monthly_kwh_per_day[month] / wtd_avg_monthly_kwh_per_day)
      end
    elsif sch_option_type == Constants.OptionTypeLightingScheduleUserSpecified
      vals = monthly_sch.split(',')
      vals.each do |val|
        begin Float(val)
        rescue
          runner.registerError('A comma-separated string of 12 numbers must be entered for the monthly schedule.')
          return false
        end
      end
      seasonal_multiplier = vals.map { |i| i.to_f }
      if seasonal_multiplier.length != 12
        runner.registerError('A comma-separated string of 12 numbers must be entered for the monthly schedule.')
        return false
      end
    end

    # Calculate normalized monthly lighting fractions
    sumproduct_seasonal_multiplier = 0
    for month in 0..11
      sumproduct_seasonal_multiplier += seasonal_multiplier[month] * num_days_in_months[month]
    end

    normalized_monthly_lighting = seasonal_multiplier
    for month in 0..11
      normalized_monthly_lighting[month] = seasonal_multiplier[month] * num_days_in_months[month] / sumproduct_seasonal_multiplier
    end

    # Calc schedule values
    lighting_sch = [[], [], [], [], [], [], [], [], [], [], [], []]
    for month in 0..11
      for hour in 0..23
        lighting_sch[month][hour] = normalized_monthly_lighting[month] * normalized_hourly_lighting[month][hour] / num_days_in_months[month]
      end
    end
    sch = []
    for month in 0..11
      sch << lighting_sch[month] * num_days_in_months[month]
    end
    sch = sch.flatten
    m = sch.max
    sch = sch.map { |s| s / m }
    return sch
  end
end

class SchedulesFile
  def initialize(runner:,
                 model:,
                 schedules_path: nil,
                 **remainder)

    @validated = true
    @runner = runner
    @model = model
    @schedules_path = schedules_path
    if @schedules_path.nil?
      @schedules_path = get_schedules_path
    end
    @external_file = get_external_file
    @schedules = {}
  end

  def validated?
    return @validated
  end

  def schedules
    return @schedules
  end

  def get_col_index(col_name:)
    headers = CSV.open(@schedules_path, 'r') { |csv| csv.first }
    col_num = headers.index(col_name)
    return col_num
  end

  def get_col_name(col_index:)
    headers = CSV.open(@schedules_path, 'r') { |csv| csv.first }
    col_name = headers[col_index]
    return col_name
  end

  def create_schedule_file(col_name:,
                           rows_to_skip: 1)
    @model.getScheduleFiles.each do |schedule_file|
      next if schedule_file.name.to_s != col_name

      return schedule_file
    end

    import(col_name: col_name)

    if @schedules[col_name].nil?
      @runner.registerError("Could not find the '#{col_name}' schedule.")
      return false
    end

    col_index = get_col_index(col_name: col_name)
    year_description = @model.getYearDescription
    num_hrs_in_year = Constants.NumHoursInYear(year_description.isLeapYear)
    schedule_length = @schedules[col_name].length
    min_per_item = 60.0 / (schedule_length / num_hrs_in_year)

    schedule_file = OpenStudio::Model::ScheduleFile.new(@external_file)
    schedule_file.setName(col_name)
    schedule_file.setColumnNumber(col_index + 1)
    schedule_file.setRowstoSkipatTop(rows_to_skip)
    schedule_file.setNumberofHoursofData(num_hrs_in_year.to_i)
    schedule_file.setMinutesperItem("#{min_per_item.to_i}")

    return schedule_file
  end

  # the equivalent number of hours in the year, if the schedule was at full load (1.0)
  def annual_equivalent_full_load_hrs(col_name:)
    import(col_name: col_name)

    year_description = @model.getYearDescription
    num_hrs_in_year = Constants.NumHoursInYear(year_description.isLeapYear)
    schedule_length = @schedules[col_name].length
    min_per_item = 60.0 / (schedule_length / num_hrs_in_year)

    ann_equiv_full_load_hrs = @schedules[col_name].reduce(:+) / (60.0 / min_per_item)

    return ann_equiv_full_load_hrs
  end

  # the power in watts the equipment needs to consume so that, if it were to run annual_equivalent_full_load_hrs hours,
  # it would consume the annual_kwh energy in the year. Essentially, returns the watts for the equipment when schedule
  # is at 1.0, so that, for the given schedule values, the equipment will consume annual_kwh energy in a year.
  def calc_design_level_from_annual_kwh(col_name:,
                                        annual_kwh:)

    ann_equiv_full_load_hrs = annual_equivalent_full_load_hrs(col_name: col_name)
    design_level = annual_kwh * 1000.0 / ann_equiv_full_load_hrs # W

    return design_level
  end

  # Similar to ann_equiv_full_load_hrs, but for thermal energy
  def calc_design_level_from_annual_therm(col_name:,
                                          annual_therm:)

    annual_kwh = UnitConversions.convert(annual_therm, 'therm', 'kWh')
    design_level = calc_design_level_from_annual_kwh(col_name: col_name, annual_kwh: annual_kwh)

    return design_level
  end

  # similar to the calc_design_level_from_annual_kwh, but use daily_kwh instead of annual_kwh to calculate the design
  # level
  def calc_design_level_from_daily_kwh(col_name:,
                                       daily_kwh:)
    full_load_hrs = annual_equivalent_full_load_hrs(col_name: col_name)
    year_description = @model.getYearDescription
    num_days_in_year = Constants.NumDaysInYear(year_description.isLeapYear)
    daily_full_load_hrs = full_load_hrs / num_days_in_year
    design_level = UnitConversions.convert(daily_kwh / daily_full_load_hrs, 'kW', 'W')

    return design_level
  end

  # thermal equivalent of calc_design_level_from_daily_kwh
  def calc_design_level_from_daily_therm(col_name:,
                                         daily_therm:)
    daily_kwh = UnitConversions.convert(daily_therm, 'therm', 'kWh')
    design_level = calc_design_level_from_daily_kwh(col_name: col_name, daily_kwh: daily_kwh)
    return design_level
  end

  # similar to calc_design_level_from_daily_kwh but for water usage
  def calc_peak_flow_from_daily_gpm(col_name:, daily_water:)
    ann_equiv_full_load_hrs = annual_equivalent_full_load_hrs(col_name: col_name)
    year_description = @model.getYearDescription
    num_days_in_year = Constants.NumDaysInYear(year_description.isLeapYear)
    daily_full_load_hrs = ann_equiv_full_load_hrs / num_days_in_year
    peak_flow = daily_water / daily_full_load_hrs # gallons_per_hour
    peak_flow /= 60 # convert to gallons per minute
    peak_flow = UnitConversions.convert(peak_flow, 'gal/min', 'm^3/s') # convert to m^3/s
    return peak_flow
  end

  # get daily gallons from the peak flow rate
  def calc_daily_gpm_from_peak_flow(col_name:, peak_flow:)
    ann_equiv_full_load_hrs = annual_equivalent_full_load_hrs(col_name: col_name)
    year_description = @model.getYearDescription
    num_days_in_year = Constants.NumDaysInYear(year_description.isLeapYear)
    peak_flow = UnitConversions.convert(peak_flow, 'm^3/s', 'gal/min')
    daily_gallons = (ann_equiv_full_load_hrs * 60 * peak_flow) / num_days_in_year
    return daily_gallons
  end

  def validate_schedule(col_name:,
                        values:)

    year_description = @model.getYearDescription
    num_hrs_in_year = Constants.NumHoursInYear(year_description.isLeapYear)
    schedule_length = values.length

    if values.max > 1
      @runner.registerError("The max value of schedule '#{col_name}' is greater than 1.")
      @validated = false
    end

    min_per_item = 60.0 / (schedule_length / num_hrs_in_year)
    unless [1, 2, 3, 4, 5, 6, 10, 12, 15, 20, 30, 60].include? min_per_item
      @runner.registerError("Calculated an invalid schedule min_per_item=#{min_per_item}.")
      @validated = false
    end
  end

  def external_file
    return @external_file
  end

  def get_external_file
    if File.exist? @schedules_path
      external_file = OpenStudio::Model::ExternalFile::getExternalFile(@model, @schedules_path)
      if external_file.is_initialized
        external_file = external_file.get
        external_file.setName(external_file.fileName)
      end
    end
    return external_file
  end

  def set_vacancy(col_name:)
    return unless @schedules.keys.include? 'vacancy'
    return if @schedules['vacancy'].all? { |i| i == 0 }

    @schedules[col_name].each_with_index do |ts, i|
      @schedules[col_name][i] *= (1.0 - @schedules['vacancy'][i])
    end
    update(col_name: col_name)
  end

  def set_outage(col_name:,
                 outage_start_date:,
                 outage_start_hour:,
                 outage_length:)

    min_per_step = 1
    if @model.getSimulationControl.timestep.is_initialized
      min_per_step = 60 / @model.getSimulationControl.timestep.get.numberOfTimestepsPerHour
    end

    year_description = @model.getYearDescription
    num_hrs_in_year = Constants.NumHoursInYear(year_description.isLeapYear)
    schedule_length = @schedules[col_name].length
    min_per_item = 60.0 / (schedule_length / num_hrs_in_year)
    sec_per_step = min_per_step * 60.0
    sim_year = year_description.calendarYear.get

    start_month = outage_start_date.split[0]
    start_day = outage_start_date.split[1].to_i
    outage_start_date = Time.new(sim_year, OpenStudio::monthOfYear(start_month).value, start_day, outage_start_hour)
    outage_end_date = outage_start_date + outage_length * 3600.0

    ts = Time.new(sim_year, 'Jan', 1)
    @schedules[col_name].each_with_index do |step, i|
      if outage_start_date <= ts && ts <= outage_end_date # in the outage period
        @schedules[col_name][i] = 0.0
      end
      ts += sec_per_step
    end

    update(col_name: col_name)
  end

  def import(col_name:)
    return if @schedules.keys.include? col_name

    col_names = [col_name, 'vacancy']
    columns = CSV.read(@schedules_path).transpose
    columns.each do |col|
      next if not col_names.include? col[0]

      values = col[1..-1].reject { |v| v.nil? }
      values = values.map { |v| v.to_f }
      validate_schedule(col_name: col[0], values: values)
      @schedules[col[0]] = values
    end
  end

  def export
    return false if @schedules_path.nil?

    CSV.open(@schedules_path, 'wb') do |csv|
      csv << @schedules.keys
      rows = @schedules.values.transpose
      rows.each do |row|
        csv << row
      end
    end

    return true
  end

  def update(col_name:)
    return false if @schedules_path.nil?

    # this is super hacky, i know.
    # it appears that when you start running the osw, the generated_files folder is automatically created (alongside the run folder).
    # the initially generated schedules.csv is placed (how?) into this generated_files folder
    # but then subsequent files of the same name are not placed into this generated_files folder (why not?)

    schedules_path = File.expand_path(File.join(File.dirname(@schedules_path), '../generated_files', File.basename(@schedules_path)))

    col_num = get_col_index(col_name: col_name)
    columns = CSV.read(schedules_path).transpose
    columns.each_with_index do |col, i|
      next unless i == col_num

      col[1..-1] = @schedules[col_name]
    end

    rows = columns.transpose
    CSV.open(schedules_path, 'wb') do |csv|
      rows.each do |row|
        csv << row
      end
    end
  end

  def get_schedules_path
    sch_path = @model.getBuilding.additionalProperties.getFeatureAsString('Schedules Path')
    if not sch_path.is_initialized # ResidentialScheduleGenerator not in workflow
      if @model.getYearDescription.isLeapYear
        sch_path = File.join(File.dirname(__FILE__), '../../../../files/8784.csv')
      else
        sch_path = File.join(File.dirname(__FILE__), '../../../../files/8760.csv')
      end
    else
      sch_path = sch_path.get
    end
    return sch_path
  end
end
