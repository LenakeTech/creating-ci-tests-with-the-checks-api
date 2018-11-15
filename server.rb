require 'sinatra'
require 'octokit'
require 'dotenv/load' # Manages environment variables
require 'git'
require 'json'
require 'openssl'     # Verifies the webhook signature
require 'jwt'         # Authenticates a GitHub App
require 'time'        # Gets ISO 8601 representation of a Time object
require 'logger'      # Logs debug statements

set :port, 3000
set :bind, '0.0.0.0'

class GHAapp < Sinatra::Application

  # Converts the newlines. Expects that the private key has been set as an
  # environment variable in PEM format.
  PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n"))

  # Your registered app must have a secret set. The secret is used to verify
  # that webhooks are sent by GitHub.
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']

  # The GitHub App's identifier (type integer) set when registering an app.
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']

  # Turn on Sinatra's verbose logging during development
  configure :development do
    set :logging, Logger::DEBUG
  end


  # Executed before each request to the `/event_handler` route
  before '/event_handler' do
    get_payload_request(request)
    verify_webhook_signature!

    # Each webhook sent to a GitHub App includes the ID of the app that triggered
    # the event. You can get notifications for events created by other apps too.
    # This conditional halts the program if the APP_IDENTIFIER doesn't match
    # your app. You can always remove this check if you plan to extend this
    # example, but you'll need to update the way `authenticate_installation`
    # gets the installation id. For example, use the repository owner and name
    # to fetch the installation id using
    # https://developer.github.com/v3/apps/#find-repository-installation.
    halt 400 unless @payload[request.env['HTTP_X_GITHUB_EVENT']]['app']['id'].to_s === APP_IDENTIFIER

    # This example uses the repository name in the webhook with command line
    # utilities. For security reasons, you should validate the repository name
    # to ensure that a bad actor isn't attempting to execute arbitrary commands
    # or inject false repository names. If a repository name is provided
    # in the webhook, validate that it consists only of latin alphabetic
    # characters, `-`, and `_`.
    halt 400 if (@payload['repository']['name'] =~ /[0-9A-Za-z\-\_]+/).nil?
      unless @payload['repository'].nil?

    authenticate_app
    # Authenticate the app installation in order to run API operations
    authenticate_installation(@payload)
  end


  post '/event_handler' do
    # Get the event type from the HTTP_X_GITHUB_EVENT header
    case request.env['HTTP_X_GITHUB_EVENT']

    when 'check_suite'
      # A new check_suite has been created. Create a new check run with status queued
      if @payload['action'] === 'requested' || @payload['action'] === 'rerequested'
        create_check_run
      end

    when 'check_run'
      case @payload['action']
      when 'created'
        initiate_check_run
      when 'rerequested'
        create_check_run
      when 'requested_action'
        take_requested_action
      end
    end
    status 200
  end


  helpers do

    # Create a new check run with the status queued
    def create_check_run
      # Octokit doesn't yet support the checks API, but it does provide generic
      # HTTP methods you can use:
      # https://developer.github.com/v3/checks/runs/#create-a-check-run
      check_run = @installation_client.post("repos/#{@payload['repository']['full_name']}/check-runs", {
          # This header allows for beta access to Checks API
          accept: 'application/vnd.github.antiope-preview+json',
          name: 'Octo Rubocop',
          # The information you need should probably be pulled from persistent
          # storage, but you can use the event that triggered the check run
          # creation. The payload structure differs depending on whether this
          # event was triggered by a check run or a check suite.
          head_sha: @payload['check_run'].nil? ? @payload['check_suite']['head_sha'] : @payload['check_run']['head_sha']
      })

      # You requested the creation of a check run from GitHub. Now, you'll wait
      # to get confirmation from GitHub that it was created before starting CI.
    end

    # Start the CI process
    def initiate_check_run
      # Once the check run is created, you'll update the status of the check run
      # to 'in_progress' and run the CI process. When the CI finishes, you'll
      # update the check run status to 'completed' and add the CI results.

      # Octokit doesn't yet support the Checks API, but it does provide generic
      # HTTP methods you can use:
      # https://developer.github.com/v3/checks/runs/#update-a-check-run
      updated_check_run = @installation_client.patch("repos/#{@payload['repository']['full_name']}/check-runs/#{@payload['check_run']['id']}", {
          accept: 'application/vnd.github.antiope-preview+json',
          name: 'Octo Rubocop',
          status: 'in_progress',
          started_at: Time.now.utc.iso8601
      })

      # ***** RUN A CI TEST *****
      # This is where you would kick off our CI process. Ideally this would be
      # performed async, so you could return immediately. But for now you'll do
      # a simulated CI process syncronously, and update the check run right here.

      full_repo_name = @payload['repository']['full_name']
      repository     = @payload['repository']['name']
      head_sha       = @payload['check_run']['head_sha']
      repository_url = @payload['repository']['html_url']

      clone_repository(full_repo_name, repository, head_sha)

      @report = `rubocop '#{repository}/*' --format json`
      `rm -rf #{repository}`
      @output = JSON.parse @report
      annotations = []

      if @output["summary"]["offense_count"] == 0
        conclusion = 'success'
      else
        conclusion = 'neutral'
        @output["files"].each do |file|
          file_path = file["path"].gsub(/#{repository}\//,'')
          annotation_level = 'notice'
          file["offenses"].each do |offense|
            start_line   = offense["location"]["start_line"]
            end_line     = offense["location"]["last_line"]
            start_column = offense["location"]["start_column"]
            end_column   = offense["location"]["last_column"]
            message      = offense["message"]
            annotation = {
              path: file_path,
              start_line: start_line,
              end_line: end_line,
              start_column: start_column,
              end_column: end_column,
              annotation_level: annotation_level,
              message: message
            }
            annotations.push(annotation)
          end
        end
      end

      summary = "Octo Rubocop summary\n-Offense count: #{@output["summary"]["offense_count"]}\n-File count: #{@output["summary"]["target_file_count"]}\n-Target file count: #{@output["summary"]["inspected_file_count"]}"
      details = "Octo Rubocop version: #{@output["metadata"]["rubocop_version"]}"

      # Now, mark the check run as complete! And if there are warnings, share them.
      updated_check_run = @installation_client.patch("repos/#{@payload['repository']['full_name']}/check-runs/#{@payload['check_run']['id']}", {
          accept: 'application/vnd.github.antiope-preview+json',
          name: 'Octo Rubocop',
          status: 'completed',
          conclusion: conclusion,
          completed_at: Time.now.utc.iso8601,
          output: {
            title: "Octo Rubocop",
            summary: summary,
            text: details,
            annotations: annotations
          },
          actions: [{
            label: "Fix this",
            description: "Automatically fix all linter notices.",
            identifier: "fix_rubocop_notices"
          }]
      })

    end

    def take_requested_action
      full_repo_name = @payload['repository']['full_name']
      repository     = @payload['repository']['name']
      head_sha       = @payload['check_run']['head_sha']
      head_branch    = @payload['check_run']['check_suite']['head_branch']
      repository_url = @payload['repository']['html_url']

      if(@payload['requested_action']['identifier'] == 'fix_rubocop_notices')
        clone_repository(full_repo_name, repository, head_sha, head_branch)

        @report = `rubocop '#{repository}/*' --format json --auto-correct`
        pwd = Dir.getwd()
        Dir.chdir(repository)
        begin
          @git.commit_all('Automatically fix Octo Rubocop notices.')
          @git.push("https://github.com/#{full_repo_name}.git", head_branch)
        rescue
          # Nothing to commit!
          puts "Nothing to commit"
        end
        Dir.chdir(pwd)
        `rm -rf #{repository}`
      end
    end

    def clone_repository(full_repo_name, repository, head_sha, head_branch=nil)
      @git = Git.clone("https://x-access-token:#{@installation_token.to_s}@github.com/#{full_repo_name}.git", repository)
      pwd = Dir.getwd()
      Dir.chdir(repository)
      @git.pull
      if(head_branch.nil?)
        @git.checkout(head_sha)
      else
        @git.checkout(head_branch)
      end
      Dir.chdir(pwd)
    end

    # Saves the raw payload and converts the payload to JSON format
    def get_payload_request(request)
      # request.body is an IO or StringIO object
      # Rewind in case someone already read it
      request.body.rewind
      # The raw text of the body is required for webhook signature verification
      @payload_raw = request.body.read
      begin
        @payload = JSON.parse @payload_raw
      rescue => e
        fail  "Invalid JSON (#{e}): #{@payload_raw}"
      end
    end

    # Instantiate an Octokit client authenticated as a GitHub App.
    # GitHub App authentication equires that you construct a
    # JWT (https://jwt.io/introduction/) signed with the app's private key,
    # so GitHub can be sure that it came from the app an not altererd by
    # a malicious third party.
    def authenticate_app
      payload = {
          # The time that this JWT was issued, _i.e._ now.
          iat: Time.now.to_i,

          # JWT expiration time (10 minute maximum)
          exp: Time.now.to_i + (10 * 60),

          # Your GitHub App's identifier number
          iss: APP_IDENTIFIER
      }

      # Cryptographically sign the JWT.
      jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')

      # Create the Octokit client, using the JWT as the auth token.
      @app_client ||= Octokit::Client.new(bearer_token: jwt)
    end

    # Instantiate an Octokit client, authenticated as an installation of a
    # GitHub App, to run API operations.
    def authenticate_installation(payload)
      installation_id = payload['installation']['id']
      @installation_token = @app_client.create_app_installation_access_token(installation_id)[:token]
      @installation_client = Octokit::Client.new(bearer_token: @installation_token)
    end

    # Check X-Hub-Signature to confirm that this webhook was generated by
    # GitHub, and not a malicious third party.
    #
    # GitHub uses the WEBHOOK_SECRET, registered to the GitHub App, to
    # create the hash signature sent in the `X-HUB-Signature` header of each
    # webhook. This code computes the expected hash signature and compares it to
    # the signature sent in the `X-HUB-Signature` header. If they don't match,
    # this request is an attack, and you should reject it. GitHub uses the HMAC
    # hexdigest to compute the signature. The `X-HUB-Signature` looks something
    # like this: "sha1=123456".
    # See https://developer.github.com/webhooks/securing/ for details.
    def verify_webhook_signature!
      their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
      method, their_digest = their_signature_header.split('=')
      our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, @payload_raw)
      halt 401 unless their_digest == our_digest

      # The X-GITHUB-EVENT header provides the name of the event.
      # The action value indicates the which action triggered the event.
      logger.debug "---- recevied event #{request.env['HTTP_X_GITHUB_EVENT']}"
      logger.debug "----    action #{@payload['action']}" unless @payload['action'].nil?
    end

  end

  # Finally some logic to let us run this server directly from the commandline,
  # or with Rack. Don't worry too much about this code ;) But, for the curious:
  # $0 is the executed file and __FILE__ is the current file. If they are the
  # same, you are running this file directly and calling the Sinatra run method.
  run! if __FILE__ == $0
end
