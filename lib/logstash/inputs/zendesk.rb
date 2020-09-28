# encoding: utf-8
require "logstash/inputs/base"
require "stud/interval"
require 'zendesk_api'

class LogStash::Inputs::Zendesk < LogStash::Inputs::Base
  config_name "zendesk"
  default :codec, "json"

  # Zendesk domain.
  #   For company.zendesk.com this parameter equals "company"
  config :domain, :validate => :string, :required => true

  # Zendesk user with admin role.
  #   Requires a Zendesk admin user account.
  config :user, :validate => :string, :required => true

  # Authentication method using user password
  config :password, :validate => :password

  # Authentication method using api token instead of password
  config :api_token, :validate => :password

  # Whether or not to fetch tickets.
  config :tickets, :validate => :boolean, :default => true

  # Whether or not to fetch ticket comments (certainly, you can only fetch comments if you are fetching tickets).
  config :comments, :validate => :boolean, :default => false

  # This parameter determines the "start_time" value for Zendesk incremental exports.
  # The workflow is as follows:
  # 	1. Try to identify last fetched time (i.e. "end_time" return value from Zendesk incremental backup) @TODO - where is it saved?
  # 	2a. If there's any last fetched time, the plugin will use it as a new start_time, i.e. only the previously unfetched date will be exported.
  # 	2b. If there's no last fetched time use this parameter (i.e. start_n_days_ago).
  # 		2b.1. if the default values (-1) is used, the plugin will set start_time=0, i.e. it will export all your Zendesk tickets (this should be executed only once)
  #		2b.2. if the value <> -1 the plugin will calculate the start_time as now() minus the given number of days and then will export the data using this starting time.
  #		      From this point on it will again use end_time as a new start_time for another execution.
  # 	If the default value (-1) is used the plugin will:
  #
  # Examples:
  # 	Use default to get all the tickets on a first run and then just a new updates on every other iteration.
  #     Use 365 to get all the tickets from the last year and the just a new updates on every other iteration.
  #
  #In other words the parameter is only useful for the very first iteration.
  config :start_n_days_ago, :validate => :number, :default => -1

  # This is the sleep time (minutes) between plugin runs.
  config :interval, :validate => :number, :default => 1

  # Add ticket field names and IDs to the log file? (for dev/config purposes)
  config :log_ticket_fields, :validate => :boolean, :default => false

# To avoid :exception=>#<RuntimeError: LogStash::Inputs::Zendesk#register must be overidden> 
  public
  def register
  end # def register

# Initiate a Zendesk client.
  def zendesk_client
    @logger.info("Creating a Zendesk client", :user => @user, :domain => @domain)
    @zd_client = ZendeskAPI::Client.new do |zconfig|
      zconfig.url = "https://#{@domain}.zendesk.com/api/v2"
      zconfig.username = @user
      if @password.nil? && @api_token.nil?
        @logger.error("Must specify either a password or api_token.", :password => @password, :api_token => @api_token)
      elsif !@password.nil? && @api_token.nil?
        zconfig.password = @password.value
      elsif @password.nil? && !@api_token.nil?
        zconfig.token = @api_token.value
      else @logger.error("Cannot specify both password and api_token input parameters.", :password => @password, :api_token => @api_token)
      end
      zconfig.retry = true # this is a feature of the Zendesk client api, it automatically retries when hitting rate limits
      if @logger.debug?
        zconfig.logger = @logger
      end
    end
    
    if @zd_client.current_user.nil?
      raise RuntimeError.new("Cannot initialize a valid Zendesk client. Please check your login credentials.")
    else
      @logger.info("Successfully initialized a Zendesk client")
    end
  end # def zendesk_client

  private
  def get_start_time(start_n_days_ago)
    if @fetch_end_time
      return @fetch_end_time
    elsif start_n_days_ago == -1
      return 0
    else
      return (Time.now.to_i - (86400 * start_n_days_ago))
    end
  end # get_start_time

  private
  def get_tickets(queue, start_time)
    begin
      get_ticket_fields
      @logger.info("Processing tickets...")

      end_of_stream = false
      page_count = 0
      prev_ticket_tid = @last_ticket_id
      prev_updated_at = @last_updated_at
      until end_of_stream # page loop
        tickets = ZendeskAPI::Ticket.incremental_export(@zd_client, start_time)
	page_count += 1
	count = 0
	@logger.info("   Processing page #{page_count}, tickets count = #{tickets.count}", :start_time => start_time)

        tickets.each do |ticket|
          if ticket.status == 'Deleted'
            # Do nothing, previously deleted tickets will show up in incremental export, but does not make sense to fetch
            @logger.info("      Skipping previously deleted ticket", :ticket_id => ticket.id)
	  elsif (ticket.id == @last_ticket_id) and (ticket.updated_at == @last_updated_at)
	    # Excluding duplicate items for time-based incremental exports (see API docs)
	    @logger.info("      Excluding duplicate item, this ticke/update was processed in previous run", :ticket_id => ticket.id, :updated_at => ticket.updated_at)
	  else
            count = count + 1
            @logger.info("      Ticket", :id => ticket.id, :progress => "#{count}/#{tickets.count}")
            process_ticket(queue,ticket)
            @logger.info("      Done processing ticket", :id => ticket.id)
          end #end Deleted status check
	  @last_ticket_id = ticket.id
	  @last_updated_at = ticket.updated_at
        end # end ticket loop

	end_of_stream = tickets.included["end_of_stream"]
	start_time = tickets.included["end_time"] # this is the start time for the next page
      end # end until, i.e. page loop

      @fetch_end_time = start_time # i.e. end_time from the last page

    # Zendesk api generates the start_time for the next page request.
    # If it ends up generating a start time that is within 5 minutes from now, it will return the following message
    # instead of a regular json response:
    # "Too recent start_time. Use a start_time older than 5 minutes".
    # This is added to ignore the message and treat it as benign.
    rescue => e
      if e.message.index 'Too recent start_time'
      # Do nothing for "Too recent start_time. Use a start_time older than 5 minutes" message returned by Zendesk api
      # This simply means that there are no more pages to fetch
        next_page = false
      else
        @logger.error(e.message, :method => "get_tickets", :trace => e.backtrace)
      end
    end
    @logger.info("Done processing tickets. Start time saved for the next iteration = #{@fetch_end_time}")
  end # def get_tickets

  private
  def process_ticket(queue, ticket)
    begin
      event = LogStash::Event.new()
      ticket.attributes.each do |k,v|
        # Zendesk incremental export api returns unfriendly field names for ticket fields (eg. field_<num>).
        # This performs conversion back to the right types based on Zendesk field naming conventions
        # and pulls in actual field names from ticket fields.  And also performs other type conversions.
	puts "#{k}, #{v}"
      end # end ticket fields
      event["type"] = "ticket"
      event["id"] = ticket.id
      #if get_comments
      #  event["comments"] = get_ticket_comments(output_queue, ticket, @append_comments_to_tickets)
      #end
      decorate(event)
      queue << event
    rescue => e
      @logger.error(e.message, :method => "process_ticket", :trace => e.backtrace)
    end
  end # process ticket

  private
  def get_ticket_fields()
    @ticketfields = Hash.new
    ticket_fields = @zd_client.ticket_fields
    ticket_fields.each do |tf|
      @ticketfields["field_#{tf.id}"] = tf.title.downcase.gsub(' ', '_')
      if @log_ticket_fields
         @logger.info("Ticket field: " + tf.title.downcase.gsub(' ', '_'), :field_id => tf.id)
      end
    end
  end # get_ticket_fields

  public
  def run(queue)
    # we can abort the loop if stop? becomes true
    while !stop?
      start = Time.now
      @logger.info("Starting Zendesk input run.", :start_time => start)
      puts "Starting Zendesk input run: " + start.to_s

      zendesk_client
      start_time = get_start_time(@start_n_days_ago)
      @tickets ? get_tickets(queue, start_time) : nil

      @logger.info("Completed in (minutes).", :duration => ((Time.now - start)/60).round(2))
      puts "Completed in: " + (((Time.now - start)/60).round(2)).to_s
      @zd_client = nil
      @logger.info("Sleeping before next run ...", :minutes => @interval)
      # because the sleep interval can be big, when shutdown happens we want to be able to abort the sleep.
      # Stud.stoppable_sleep will frequently evaluate the given block and abort the sleep(@interval) if the return value is true
      Stud.stoppable_sleep(@interval * 60) { stop? }
    end # loop
  end # def run

  public
  def stop
    # nothing to do in this case so it is not necessary to define stop
    # examples of common "stop" tasks:
    #  * close sockets (unblocking blocking reads/accepts)
    #  * cleanup temporary files
    #  * terminate spawned threads
  end # def stop

end # class LogStash::Inputs::Zendesk
