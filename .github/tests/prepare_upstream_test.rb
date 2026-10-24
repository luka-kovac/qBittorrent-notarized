# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../scripts/prepare_upstream"

class PrepareUpstreamTest < Minitest::Test
  def workflow(tag = "release-5.3.0")
    YAML.safe_load(File.read(File.join(__dir__, "fixtures", "#{tag}.yaml")), aliases: false)
  end

  def test_both_release_workflows_preserve_all_build_commands_and_action_versions
    %w[release-5.2.0 release-5.3.0].each do |tag|
      source = workflow(tag)
      action, outputs = UpstreamBuild.prepare(source)
      job = source.fetch("jobs").fetch("ci")
      assert_equal job.dig("strategy", "matrix"), outputs.fetch("matrix")
      assert_equal job.fetch("runs-on"), outputs.fetch("runner")
      generated = action.fetch("runs").fetch("steps").drop(1)
      assert_equal job.fetch("steps").drop(1).length, generated.length
      job.fetch("steps").drop(1).zip(generated).each do |upstream, adapted|
        expected = UpstreamBuild.rewrite(upstream)
        assert_equal expected.fetch("name"), adapted.fetch("name")
        if upstream.fetch("name") == "Prepare build artifacts"
          before, after = expected.fetch("run").split(/# code signing\n.*?# create \.dmg\n/m)
          assert adapted.fetch("run").start_with?(before)
          assert adapted.fetch("run").end_with?(after)
          assert_includes adapted.fetch("run"), 'bash "${GITHUB_ACTION_PATH}/notarize.sh" "${appName}.app"'
          refute_includes adapted.fetch("run"), "codesign --force --sign -"
        else
          # Everything except the explicit composite shell stays identical.
          adapted = adapted.reject { |key, _| key == "shell" && !upstream.key?("shell") }
          assert_equal expected, adapted
        end
      end
    end
  end

  def test_upstream_changes_flow_through_without_local_version_or_command_updates
    source = workflow
    job = source.fetch("jobs").fetch("ci")
    job["runs-on"] = "macos-27"
    job["timeout-minutes"] = 90
    job["strategy"]["max-parallel"] = 2
    job["strategy"]["matrix"]["qt_version"] = ["7.0.0"]
    job["strategy"]["matrix"]["new_axis"] = ["one", "two"]
    job["strategy"]["matrix"]["exclude"] = [{ "new_axis" => "two", "qbt_gui" => "GUI=OFF" }]
    job["strategy"]["matrix"]["include"] = [{ "new_axis" => "one", "extra_flag" => "-DFUTURE=ON" }]
    job.fetch("steps").insert(3, { "name" => "New upstream check", "run" => "echo '${{ matrix.extra_flag }}'" })
    dependencies = job.fetch("steps").find { |step| step.fetch("name") == "Install dependencies" }
    dependencies["uses"] = "upstream/new-installer@v9"
    dependencies["with"]["command"] += "brew install new-dependency\n"
    action, outputs = UpstreamBuild.prepare(source)
    assert_equal job.fetch("strategy").fetch("matrix"), outputs.fetch("matrix")
    assert_equal "macos-27", outputs.fetch("runner")
    assert_equal 90, outputs.fetch("timeout")
    assert_equal 2, outputs.fetch("max_parallel")
    generated = action.fetch("runs").fetch("steps")
    assert_equal UpstreamBuild.rewrite(dependencies), generated.find { |step| step.fetch("name") == "Install dependencies" }
    assert_includes generated.find { |step| step.fetch("name") == "New upstream check" }.fetch("run"), "fromJSON(inputs.matrix).extra_flag"
  end

  def test_current_upstream_openssl_fix_is_inherited_verbatim
    source = workflow
    action, = UpstreamBuild.prepare(source)
    commands = action.dig("runs", "steps").find { |step| step["name"] == "Install dependencies" }.dig("with", "command")
    assert_equal source.dig("jobs", "ci", "steps", 1, "with", "command"), commands
    assert_includes commands, 'echo "CMAKE_PREFIX_PATH=/opt/homebrew/opt/openssl@3" >> "$GITHUB_ENV"'
  end

  def test_environment_export_preserves_multiline_values_and_does_not_reset_later_steps
    source = workflow
    source["env"] = { "MULTILINE" => "first\nsecond", "CMAKE_PREFIX_PATH" => "/initial" }
    action, = UpstreamBuild.prepare(source)
    steps = action.dig("runs", "steps")
    bootstrap = steps.first
    Dir.mktmpdir do |dir|
      output = File.join(dir, "env")
      env = bootstrap.fetch("env").merge("GITHUB_ENV" => output)
      stdout, stderr, status = Open3.capture3(env, "bash", "-e", stdin_data: bootstrap.fetch("run"))
      assert status.success?, "#{stdout}\n#{stderr}"
      assert_includes File.read(output), "first\nsecond\n"
      assert_includes File.read(output), "/initial\n"
    end
    steps.drop(1).each { |step| refute step.fetch("env", {}).key?("CMAKE_PREFIX_PATH") }
  end

  def test_signing_secrets_are_only_passed_to_the_packaging_step
    action, = UpstreamBuild.prepare(workflow)
    action.dig("runs", "steps").each do |step|
      keys = step.fetch("env", {}).keys & UpstreamBuild::SECRET_NAMES.map(&:upcase)
      if step["name"] == "Prepare build artifacts"
        assert_equal UpstreamBuild::SECRET_NAMES.length, keys.length
      else
        assert_empty keys
      end
    end
  end

  def test_changed_packaging_boundaries_fail_before_any_build_or_publication
    source = workflow
    packaging = source.dig("jobs", "ci", "steps").find { |step| step["name"] == "Prepare build artifacts" }
    packaging["run"].sub!("# create .dmg", "# totally different packaging")
    error = assert_raises(RuntimeError) { UpstreamBuild.prepare(source) }
    assert_includes error.message, "packaging layout changed"
  end

  def test_unknown_job_and_step_features_are_not_silently_dropped
    source = workflow
    source.dig("jobs", "ci")["container"] = "example/image"
    assert_raises(RuntimeError) { UpstreamBuild.prepare(source) }
    source = workflow
    source.dig("jobs", "ci", "steps", 2)["timeout-minutes"] = 5
    assert_raises(RuntimeError) { UpstreamBuild.prepare(source) }
    source = workflow
    source.dig("jobs", "ci", "steps", 0)["with"]["submodules"] = true
    assert_raises(RuntimeError) { UpstreamBuild.prepare(source) }
  end

  def test_generated_shell_commands_are_valid_for_both_releases
    %w[release-5.2.0 release-5.3.0].each do |tag|
      action, = UpstreamBuild.prepare(workflow(tag))
      action.dig("runs", "steps").each do |step|
        command = step["run"] || step.dig("with", "command")
        next unless command
        command = command.gsub(/\$\{\{.*?\}\}/m, "placeholder")
        _, stderr, status = Open3.capture3("bash", "-n", stdin_data: command)
        assert status.success?, "#{tag}/#{step['name']}: #{stderr}"
      end
    end
  end

  def test_notarization_uses_the_created_zip_and_cleans_up_on_success_and_failure
    [false, true].each do |reject_submission|
      Dir.mktmpdir do |dir|
        bin = File.join(dir, "bin")
        FileUtils.mkdir_p(bin)
        FileUtils.mkdir_p(File.join(dir, "qbittorrent.app", "Contents", "MacOS"))
        %w[xattr].each do |tool|
          path = File.join(bin, tool)
          File.write(path, "#!/usr/bin/env bash\nexit 0\n")
          File.chmod(0o755, path)
        end
        File.write(File.join(bin, "security"), <<~'BASH')
          #!/usr/bin/env bash
          set -euo pipefail
          if [[ "$1" == list-keychains ]]; then
            if [[ " $* " == *" -s "* ]]; then
              touch "$RUNNER_TEMP/keychain-searchable"
            else
              echo '    "/runner/login.keychain-db"'
            fi
          elif [[ "$1" == default-keychain && " $* " != *" -s "* ]]; then
            echo '    "/runner/login.keychain-db"'
          fi
        BASH
        File.write(File.join(bin, "codesign"), <<~'BASH')
          #!/usr/bin/env bash
          # Model codesign's search-list requirement, beyond successful import.
          test -f "$RUNNER_TEMP/keychain-searchable"
        BASH
        File.write(File.join(bin, "ditto"), "#!/usr/bin/env bash\ntouch \"${@: -1}\"\n")
        File.write(File.join(bin, "xcrun"), <<~'BASH')
          #!/usr/bin/env bash
          set -euo pipefail
          echo "$1 $2" >> "$RUNNER_TEMP/apple-calls"
          if [[ "$1 $2" == "notarytool submit" ]]; then
            test -f "$3"
            if [[ "$REJECT_SUBMISSION" == true ]]; then exit 42; fi
          fi
        BASH
        %w[security codesign ditto xcrun].each { |tool| File.chmod(0o755, File.join(bin, tool)) }
        env = UpstreamBuild::SECRET_NAMES.to_h { |name| [name.upcase, "dummy"] }
        env.merge!("BUILD_CERTIFICATE_BASE64" => ["certificate"].pack("m0"),
                   "RUNNER_TEMP" => dir, "PATH" => "#{bin}:#{ENV.fetch('PATH')}",
                   "REJECT_SUBMISSION" => reject_submission.to_s)
        script = File.expand_path("../scripts/notarize.sh", __dir__)
        stdout, stderr, status = Open3.capture3(env, "bash", script, "qbittorrent.app", chdir: dir)
        assert_equal(reject_submission ? 42 : 0, status.exitstatus, "#{stdout}\n#{stderr}")
        calls = File.read(File.join(dir, "apple-calls"))
        if reject_submission
          refute_includes calls, "stapler staple"
        else
          assert_includes calls, "stapler staple"
          assert_includes calls, "stapler validate"
        end
        assert_empty Dir.glob(File.join(dir, "notarize.*"))
      end
    end
  end
end
