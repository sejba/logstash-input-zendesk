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

  # This is the criteria for fetching tickets in the form of last updated N days ago.
  # Updated tickets include new tickets.
  #   Examples:
  #     0.5 = updated in the past 12 hours
  #     1  = updated in the past day
  #     7 = updated in the past week
  #     -1 = get all tickets (when this mode is chosen, the plugin will run only once, not continuously)
  config :tickets_last_updated_n_days_ago, :validate => :number, :default => 1

  # This is the sleep time (minutes) between plugin runs. Does not apply when tickets_last_updated_n_days_ago => -1.
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
  def get_tickets(queue, last_updated_n_days, get_comments)
    begin
      @ticketfields = Hash.new
      ticket_fields = @zd_client.ticket_fields
      ticket_fields.each do |tf|
        @ticketfields["field_#{tf.id}"] = tf.title.downcase.gsub(' ', '_')
	if @log_ticket_fields
	  @logger.info("Ticket field: " + tf.title.downcase.gsub(' ', '_'), :field_id => tf.id)
	end
      end
      if last_updated_n_days != -1
        start_time = Time.now.to_i - (86400 * last_updated_n_days)
      else
        start_time = 0
      end
      @logger.info("Processing tickets...", :start_time => start_time)
      tickets = ZendeskAPI::Ticket.incremental_export(@zd_client, start_time)
      next_page_from_each = ""
      next_page_from_next = ""
      count = 0
      next_page = true
      while next_page && tickets.count > 0
        @logger.info("Next page from Zendesk api", :next_page_url => tickets.instance_variable_get("@next_page"))
        @logger.info("Number of tickets returned from current incremental export page request", :count => tickets.count)
        tickets.each do |ticket|
          next_page_from_each = tickets.instance_variable_get("@next_page")
          if ticket.status == 'Deleted'
            # Do nothing, previously deleted tickets will show up in incremental export, but does not make sense to fetch
            @logger.info("Skipping previously deleted ticket", :ticket_id => ticket.id)
          else
            count = count + 1
            @logger.info("Ticket", :id => ticket.id, :progress => "#{count}/#{tickets.count}")
            #process_ticket(output_queue,ticket,get_comments)
            @logger.info("Done processing ticket", :id => ticket.id)
          end #end Deleted status check
        end # end ticket loop
        tickets.next
        next_page_from_next = tickets.instance_variable_get("@next_page")
        # Zendesk api creates a next page attribute in its incremental export response including a generated
        # start_time for the "next page" request.  Occasionally, it generates
        # the next page request with the same start_time as the originating request.
        # When this happens, it will keep requesting the same page over and over again.  Added a check to workaround this
        # behavior.
        if next_page_from_next == next_page_from_each
          next_page = false
        end
        count = 0
      end # end while
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
    @logger.info("Done processing tickets.")
  end # def get_tickets

  public
  def run(queue)
    # we can abort the loop if stop? becomes true
    while !stop?
      start = Time.now
      @logger.info("Starting Zendesk input run.", :start_time => start)
      puts "Starting Zendesk input run: " + start.to_s
      zendesk_client
      @tickets ? get_tickets(queue, @tickets_last_updated_n_days_ago, @comments) : nil
      @logger.info("Completed in (minutes).", :duration => ((Time.now - start)/60).round(2))
      puts "Completed in: " + (((Time.now - start)/60).round(2)).to_s
      @zd_client = nil
      if @tickets_last_updated_n_days_ago == -1
        break
      end
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
