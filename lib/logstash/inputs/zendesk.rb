# encoding: utf-8
require "logstash/inputs/base"
require "stud/interval"
require 'zendesk_api'

# @TODO: Add the plugin description

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
    ticket = ZendeskAPI::Ticket.find!(@zd_client, :id => 16238)
    puts "Ticket priority: "+ticket.priority
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
