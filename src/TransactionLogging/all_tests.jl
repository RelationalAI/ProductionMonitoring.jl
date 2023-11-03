@testitem "TransactionLogging" begin

using ProductionMonitoring.TransactionLogging

using Logging
using Dates
using JSON3
using ScopedValues
using DeepDiffs

@testset "Basic logging" begin
    @testset for logger_type in
                 [JSONLogger, LocalLogger]
        log_buffer = IOBuffer()
        Logging.with_logger(logger_type(stream=log_buffer)) do
            @info "my message"
        end
        generated_log_message = String(take!(log_buffer))
        @test occursin("my message", generated_log_message)
        # verify transaction_id doesn't appear when not set on logger
        @test !occursin("transaction_id", generated_log_message)

        Logging.with_logger(logger_type(stream=log_buffer, transaction_id="100")) do
            @info "my transaction message"
        end
        generated_log_message = String(take!(log_buffer))
        @test occursin("my transaction message", generated_log_message)
        @test occursin("transaction_id", generated_log_message)
    end
end

const my_test_scoped_val = ScopedValue{Any}()

@testset "Basic logging with scoped values" begin
    @testset for logger_type in
                 [JSONLogger, LocalLogger]
        log_buffer = IOBuffer()
        Logging.with_logger(logger_type(stream=log_buffer, transaction_id="100")) do
            with(my_test_scoped_val => "ooh hi") do
                @info "my message" my_test_scoped_val[]
            end
        end
        generated_log_message = String(take!(log_buffer))
        @test occursin("my message", generated_log_message)
        @test occursin("my_test_scoped_val", generated_log_message)
        @test occursin("ooh hi", generated_log_message)
        # make sure that the scoped value usage doesn't prevent the log message from
        # getting the attributes from our logger
        @test occursin("transaction_id", generated_log_message)
    end
end

@testset "Backtrace logging" begin
    @testset for logger_type in
                 [JSONLogger, LocalLogger]
        log_buffer = IOBuffer()
        Logging.with_logger(logger_type(stream=log_buffer)) do
            @warn_with_current_backtrace "uh oh"
        end
        generated_log_message = String(take!(log_buffer))
        @test occursin("uh oh", generated_log_message)
        # verify that a line printed by the internal Base.display_error formatting apppears
        @test occursin("Stacktrace:", generated_log_message)
        # verify that a known part of the stacktrace appears; this assumes that the
        # with_logger function will appear within the first 9 lines, which should be
        # robust to minor implementation changes within Julia.
        @test occursin(r"\[[1-9]\] with_logger", generated_log_message)
        # verify that the final line contains the correct source file
        @test occursin(
            r"@ .*TransactionLogging/all_tests.jl:",
            generated_log_message,
        )
    end
end

@testset "Stacktrace logging" begin
    @testset for logger_type in
                 [JSONLogger, LocalLogger]
        log_buffer = IOBuffer()
        Logging.with_logger(logger_type(stream=log_buffer)) do
            try
                error("oh my, an error!")
            catch
                @error_with_current_exceptions "uh oh"
            end
        end
        generated_log_message = String(take!(log_buffer))
        @test occursin("oh my, an error!", generated_log_message)
        @test occursin("uh oh", generated_log_message)
        # verify that a line printed by the internal Base.display_error formatting apppears
        @test occursin("Stacktrace:", generated_log_message)
        # verify that a known part of the stacktrace appears; this assumes that the
        # with_logger function will appear within the first 9 lines, which should be
        # robust to minor implementation changes within Julia.
        @test occursin(r"\[[1-9]\] with_logger", generated_log_message)
        # verify that the final line contains the correct source file
        @test occursin(
            r"@ .*TransactionLogging/all_tests.jl:",
            generated_log_message,
        )
    end
end

# Separate these out so that the exception logging doesn't mess up because
# of anonymous closures.
assertion1() = @assert 1 != 1
assertion2() = @assert 2 != 2
assertion3() = @assert 3 != 3
@testset "Complex exception logging" begin
    _mod = @__MODULE__
    replace_file_line(str) =
        replace(str, Regex("@ $_mod \\S*") => " @ Main FILE:LINE", r"@ \S*" => " @ FILE:LINE")

    @testset for logger_type in
                 [TransactionLogging.JSONLogger, TransactionLogging.LocalLogger]
        log_buffer = IOBuffer()
        # Test the above function which throws exceptions.
        Logging.with_logger(logger_type(stream=log_buffer)) do
            try
                try
                    @sync begin
                        Threads.@spawn try
                            @assert false
                        catch
                            assertion1()
                        end
                        Threads.@spawn assertion2()
                    end
                catch
                    @assert assertion3()
                end
            catch
                TransactionLogging.@error_with_current_exceptions "test pretty printing"
            end
        end
        seekstart(log_buffer)
        generated_log_message = String(take!(log_buffer))
        if logger_type == TransactionLogging.JSONLogger
            log_obj = JSON3.read(generated_log_message)
            log_msg_str = replace_file_line(log_obj.message)
            # NOTE: This test is very whitespace sensitive. Take care when changing
            # indentation!
@static if VERSION >= v"1.10.0-" # RAI-15178
            @test startswith(log_msg_str, r"""
                \Qtest pretty printing

                === EXCEPTION SUMMARY ===

                CompositeException (2 tasks):
                 1. AssertionError: false
                     [1] (::Main.var"##TransactionLogging#\E\d+\Q".var"#\E\d+\Q#\E\d+\Q")()
                        @ Main FILE:LINE

                    which caused:
                    AssertionError: 1 != 1
                     [1] assertion1()
                        @ Main FILE:LINE
                 --
                 2. AssertionError: 2 != 2
                     [1] assertion2()
                        @ Main FILE:LINE

                which caused:
                AssertionError: 3 != 3
                 [1] assertion3()
                    @ Main FILE:LINE

                ===========================

                Original Error message:

                ERROR: AssertionError: 3 != 3
                Stacktrace:\E
                """)
else
            @test startswith(log_msg_str, """
                test pretty printing

                === EXCEPTION SUMMARY ===

                CompositeException (2 tasks):
                 1. AssertionError: false
                     [1] macro expansion
                        @ FILE:LINE [inlined]

                    which caused:
                    AssertionError: 1 != 1
                     [1] assertion1()
                        @ Main FILE:LINE
                 --
                 2. AssertionError: 2 != 2
                     [1] assertion2()
                        @ Main FILE:LINE

                which caused:
                AssertionError: 3 != 3
                 [1] assertion3()
                    @ Main FILE:LINE

                ===========================

                Original Error message:

                ERROR: AssertionError: 3 != 3
                Stacktrace:
                """)
end
        else
            @test occursin("EXCEPTION SUMMARY", generated_log_message)
            @test occursin("ERROR: AssertionError: 3 != 3", generated_log_message)
        end
    end
end

@testset "Stacktrace logging with args" begin
    @testset for logger_type in
                 [JSONLogger, LocalLogger]
        log_buffer = IOBuffer()
        Logging.with_logger(logger_type(stream=log_buffer)) do
            try
                error("oh my, an error!")
            catch
                local_variable = "local variable"
                @error_with_current_exceptions "extra context:" first_kwarg = "spare kwarg" second_kwarg =
                    local_variable
            end
        end
        generated_log_message = String(take!(log_buffer))
        @test occursin("oh my, an error!", generated_log_message)
        # verify that a line printed by the internal Base.display_error formatting apppears
        @test occursin("Stacktrace:", generated_log_message)
        # verify that a known part of the stacktrace appears; this assumes that the
        # with_logger function will appear within the first 9 lines, which should be
        # robust to minor implementation changes within Julia.
        @test occursin(r"\[[1-9]\] with_logger", generated_log_message)
        # make sure both the message body and extra_kwarg make it into the final message
        @test occursin("extra context:", generated_log_message)
        @test occursin(r"first_kwarg.*spare kwarg", generated_log_message)
        @test occursin(r"second_kwarg.*local variable", generated_log_message)
    end
end

@testset "Log every n with scoped value" begin
    @testset for logger_type in
                 [JSONLogger, LocalLogger]
        log_buffer = IOBuffer()
        Logging.with_logger(logger_type(stream=log_buffer)) do
            with(my_test_scoped_val => "ooh hi") do
                t = Dates.now()
                local_variable = "local variable"
                for i in 1:5
                    @info "logging $i"
                end
                while Dates.now() < t + Dates.Second(3)
                    @warn_every_n_seconds 2 "not too often!" first_kwarg = "spare kwarg" second_kwarg =
                        local_variable
                end
            end
        end
        generated_log_message = String(take!(log_buffer))
        # The message should be logged out twice; once at the beginning of the 3s interval, and
        # once at the 2s mark.
        @test occursin(r"not too often!.*(\n.*)*not too often!", generated_log_message)
        # But not thrice!
        @test !occursin(
            r"not too often!.*(\n.*)*not too often!.*(\n.*)*not too often!",
            generated_log_message,
        )
        # verify that the final line contains the correct source file
        @test occursin(
            r"@ .*TransactionLogging/all_tests.jl:",
            generated_log_message,
        )
        @test occursin(r"first_kwarg.*spare kwarg", generated_log_message)
        @test occursin(r"second_kwarg.*local variable", generated_log_message)
        # make sure all normal log messages appear
        for i in 1:5
            @test occursin("logging $i", generated_log_message)
        end
    end
end

@testset "Request id SubString" begin
    @testset for logger_type in
                 [JSONLogger, LocalLogger]
        log_buffer = IOBuffer()
        request_id = SubString("im_an_id")
        Logging.with_logger(logger_type(stream=log_buffer)) do
            @info "my message"
        end
        generated_log_message = String(take!(log_buffer))
        @test occursin("my message", generated_log_message)
        # verify transaction_id doesn't appear when not set on logger
        @test !occursin("request_id", generated_log_message)

        Logging.with_logger(
            logger_type(stream=log_buffer, request_id=request_id, transaction_id="100"),
        ) do
            @info "my transaction message"
        end
        generated_log_message = String(take!(log_buffer))
        @test occursin("my transaction message", generated_log_message)
        @test occursin("request_id", generated_log_message)
        @test occursin("$request_id", generated_log_message)
    end
end

@testset "Log non-string message" begin
    @testset for logger_type in
                 [JSONLogger, LocalLogger]
        log_buffer = IOBuffer()
        Logging.with_logger(logger_type(stream=log_buffer)) do
            @info AssertionError("this is an assertion error")
        end
        generated_log_message = String(take!(log_buffer))
        # AssertionError can't be concatenated with a string using *
        # This test verifies that the message argument is correctly converted to a string
        @test occursin(r"this is an assertion error", generated_log_message)
    end
end

@testset "Get request id" begin
    @testset for logger_type in
                 [JSONLogger, LocalLogger]
        log_buffer = IOBuffer()
        request_id = SubString("im_an_id")
        extracted_request_id = ""
        Logging.with_logger(logger_type(stream=log_buffer, request_id=request_id)) do
            extracted_request_id = TransactionLogging.get_request_id()
        end
        @test extracted_request_id == request_id
    end
end

@testset "Set commit (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(JSONLogger(stream=log_buffer)) do
        @info "my message"
    end
    generated_log_message = String(take!(log_buffer))
    # verify commit doesn't appear when not set on logger
    @test !occursin("commit", generated_log_message)

    Logging.with_logger(
        JSONLogger(stream=log_buffer, commit="my-commit"),
    ) do
        @info "my transaction message"
    end
    generated_log_message = String(take!(log_buffer))
    @test occursin("commit", generated_log_message)
end

@testset "Set build timestamp (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(JSONLogger(stream=log_buffer)) do
        @info "my message"
    end
    generated_log_message = String(take!(log_buffer))
    # verify commit doesn't appear when not set on logger
    @test !occursin("build_timestamp", generated_log_message)

    Logging.with_logger(
        JSONLogger(stream=log_buffer, build_timestamp="20220110000001"),
    ) do
        @info "my transaction message"
    end
    generated_log_message = String(take!(log_buffer))
    @test occursin("build_timestamp", generated_log_message)
end

@testset "Max message size (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            max_message_size=3,
            transaction_id="100",
        ),
    ) do
        # exactly 10 characters should produce 4 logs messages of size <=3
        @info "0123456789"
    end
    expected_msgs = ["012", "345", "678", "9"]
    generated_log_message = String(take!(log_buffer))
    msgs = split(generated_log_message, "\n"; keepempty=false)

    for i in 1:4
        msg = msgs[i]
        # check for the numbering marker
        @test occursin("log message $i of 4", msg)
        # make sure the tags appear on each log message
        @test occursin("transaction_id", msg)
        @test occursin(expected_msgs[i], msg)
    end
end

@testset "Max message size with long chars (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            max_message_size=5,
            transaction_id="100",
        ),
    ) do
        # 6 characters of size ??
        @info "aaa∀aa"
    end
    expected_msgs = ["aaa∀", "aa"]
    generated_log_message = String(take!(log_buffer))
    msgs = split(generated_log_message, "\n")

    for i in 1:2
        # check for the numbering marker
        @test occursin("log message $i of 2", generated_log_message)
        # make sure the tags appear on each log message
        @test occursin("transaction_id", generated_log_message)
        @test occursin(expected_msgs[i], generated_log_message)
    end
end

@testset "Max attribute lengths (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            max_message_size=55,
            attr_char_limit=4,
            transaction_id="100",
        ),
    ) do
        @info "0123456789" hi1doesntfit = "toolong" hi2 = "muchtoolong" longchar = "aa∀aa"
    end
    expected_msg = "0123456789"
    generated_log_message = String(take!(log_buffer))
    msgs = split(generated_log_message, "\n"; keepempty=false)
    @test length(msgs) == 2
    json1 = JSON3.read(msgs[1])
    json2 = JSON3.read(msgs[2])
    @test occursin(expected_msg, json1.message)

    # attributes should appear on both messages
    @test json1.attrs.hi1d == "tool"
    @test json1.attrs.hi2 == "much"
    @test json1.attrs.long == "aa∀"
    @test json2.attrs.hi1d == "tool"
    @test json2.attrs.hi2 == "much"
    @test json2.attrs.long == "aa∀"
    @test occursin("dropped attributes:", generated_log_message)

    # the addition of the attributes to the message text makes it overflow into two messages
    @test occursin("hi1doesntfit: toolong", json1.message)
    # the key gets split between messages, so we just check that the value made it
    @test occursin("muchtoolong", json2.message)
end

@testset "Max dbname length (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            attr_char_limit=4,
            transaction_id="100",
        ),
    ) do
        TransactionLogging.set_database_name!(Logging.current_logger(), "truncatable_db_name")
        @info "0123456789"
    end
    expected_msg = "0123456789"
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test occursin(expected_msg, json.message)
    # the truncated db name should appear in the tags
    @test json["rai.database_name"] == "trun"
    # the full dbname should appear in the body
    @test occursin("full rai.database_name: truncatable_db_name", json.message)
end

@testset "set_database_name! (JSONLogger only)" begin
    log_buffer = IOBuffer()
    expected_msg = "very important log message"
    db_name = "very_imp_data"
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
        ),
    ) do
        logger = Logging.current_logger()
        TransactionLogging.set_database_name!(logger, db_name)
        @info expected_msg my_database_name=TransactionLogging.get_database_name(logger)
    end
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test json.message == expected_msg
    # check that setting the database name worked
    @test json["rai.database_name"] == db_name
    # indirectly check that getting the database name worked
    @test json.attrs["my_database_name"] == db_name
end

@testset "set_database_id! (JSONLogger only)" begin
    log_buffer = IOBuffer()
    expected_msg = "very important log message"
    db_id = "28b392cd-e9f6-956e-f4a4-3beb7019d521"
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
        ),
    ) do
        logger = Logging.current_logger()
        TransactionLogging.set_database_id!(logger, db_id)
        @info expected_msg my_database_id=TransactionLogging.get_database_id(logger)
    end
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test json.message == expected_msg
    # check that setting the database id worked
    @test json["rai.database_id"] == db_id
    # indirectly check that getting the database id worked
    @test json.attrs["my_database_id"] == db_id
end

@testset "set_database_name_and_id! (JSONLogger only)" begin
    log_buffer = IOBuffer()
    expected_msg = "very important log message"
    db_name = "service-review"
    db_id = "28b392cd-e9f6-956e-f4a4-3beb7019d521"
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
        ),
    ) do
        logger = Logging.current_logger()
        TransactionLogging.set_database_name_and_id!(logger, db_name, db_id)
        found_db_name = TransactionLogging.get_database_name(logger)
        found_db_id = TransactionLogging.get_database_id(logger)
        @info expected_msg my_database_name=found_db_name my_database_id=found_db_id
    end
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test json.message == expected_msg
    # check that setting the database name and id worked
    @test json["rai.database_name"] == db_name
    @test json["rai.database_id"] == db_id
    # indirectly check that getting the database name and id worked
    @test json.attrs["my_database_name"] == db_name
    @test json.attrs["my_database_id"] == db_id
end

@testset "Max attribute character count (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            max_attr_char_count=20,
            attr_char_limit=4,
            transaction_id="100",
        ),
    ) do
        @info "0123456789" hi1 = "beep" hi2 = "boop" hi3 = "burp" hi4 = "barf"
    end
    expected_msg = "0123456789"

    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)

    @test occursin(expected_msg, json.message)
    @test json.attrs.hi1 == "beep"
    @test json.attrs.hi2 == "boop"
    @test !haskey(json.attrs, :hi3)
    @test !haskey(json.attrs, :hi4)
    @test occursin("dropped attributes:", json.message)

    # make sure the overflow attribute occurs in the message body
    @test occursin("hi3: burp", generated_log_message)
    @test occursin("hi4: barf", generated_log_message)
    # make sure non-overflow attributes don't show up in the body (they were in the tags)
    @test !occursin("hi1: beep", generated_log_message)
    @test !occursin("hi2: boop", generated_log_message)
end

@testset "Max attribute character count dict edition - attributes dropped (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            max_attr_char_count=20,
            attr_char_limit=4,
            transaction_id="100",
        ),
    ) do
        @info "0123456789" hi = Dict(
            1 => "too long",
            2 => "should get truncated",
            3 => "how many is too many?",
            4 => "okay last one",
        )
    end
    expected_msg = "0123456789"
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test occursin(expected_msg, json.message)

    # only 3 of the kv pairs should be able to fit in attributes under the character count,
    # but since the dict is unordered we just check count instead of identity
    dict_attr_count =
        (haskey(json.attrs.hi, 1) && json.attrs.hi[1] == "too " ? 1 : 0) +
        (haskey(json.attrs.hi, 2) && json.attrs.hi[2] == "shou" ? 1 : 0) +
        (haskey(json.attrs.hi, 3) && json.attrs.hi[3] == "how " ? 1 : 0) +
        (haskey(json.attrs.hi, 4) && json.attrs.hi[4] == "okay" ? 1 : 0)
    @test dict_attr_count == 3

    # make sure the overflow attribute occurs in the message body
    @test occursin("dropped attributes:", json.message)
    # make sure the whole dict ends up in the message
    @test occursin("hi: Dict", json.message)
    @test occursin("too long", json.message)
    @test occursin("should get truncated", json.message)
    @test occursin("how many is too many?", json.message)
    @test occursin("okay last one", json.message)
end

@testset "Max attribute character count dict edition - attributes truncated (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            max_attr_char_count=200,
            attr_char_limit=7,
            transaction_id="100",
        ),
    ) do
        @info "0123456789" hi = Dict(
            1 => "is fine",
            2 => "this one is too long but should not bork the others",
            # this one should still be a number in the JSON
            3 => 200000,
            4 => "yes",
            # this one should get truncated and turned into a string because it's 8 characters
            5 => 10000000
        )
    end
    expected_msg = "0123456789"
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test occursin(expected_msg, json.message)

    @test json.attrs.hi[1] == "is fine"
    @test json.attrs.hi[2] == "this on"
    @test json.attrs.hi[3] == 200000
    @test json.attrs.hi[4] == "yes"
    # this is a string instead of a number because it was truncated
    @test json.attrs.hi[5] == "1000000"

    # make sure the overflow attribute occurs in the message body
    @test occursin("dropped attributes:", json.message)
    # make sure the whole dict ends up in the message
    @test occursin("hi: Dict", json.message)
    @test occursin("is fine", json.message)
    @test occursin("this one is too long but should not bork the others", json.message)
    @test occursin("200000", json.message)
    @test occursin("10000000", json.message)
    @test occursin("yes", json.message)
end

@testset "Max attribute character count nested dict edition (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            max_attr_char_count=200,
            attr_char_limit=10,
            transaction_id="100",
        ),
    ) do
        @info "0123456789" hi = Dict(
            1 => "is fine",
            2 => Dict(:inner => "fine", :big_inner => "definitely not fine this should be truncated"),
            3 => "I'm okay",
            4 => "yes",
        )
    end
    expected_msg = "0123456789"
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test occursin(expected_msg, json.message)

    @test json.attrs.hi[1] == "is fine"
    @test json.attrs.hi[2].inner == "fine"
    @test json.attrs.hi[2].big_inner == "definitely"
    @test json.attrs.hi[3] == "I'm okay"
    @test json.attrs.hi[4] == "yes"

    # make sure the overflow attribute occurs in the message body
    @test occursin("dropped attributes:", json.message)
    # make sure the whole dict ends up in the message
    @test occursin("hi: Dict", json.message)
    @test occursin("1 => \"is fine\"", json.message)
    @test occursin("definitely not fine this should be truncated", json.message)
    @test occursin("3 => \"I'm okay\"", json.message)
    @test occursin("4 => \"yes\"", json.message)
end

@testset "Max attribute character count named tuple (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            max_attr_char_count=200,
            attr_char_limit=10,
            transaction_id="100",
        ),
    ) do
        # note that if you pass a named tuple directly, it might be formatted weirdly in the
        # outputted log, particularly if it gets truncated.
        # @info "hi" (; part1 = 10, part2 = 20)
        # looks bad if it exceeds the character count, but the following usages are fine
        x = (; part1 = 10, part2 = 20)
        @info "0123456789" x y=(; part3 = "very long string", part4 = 40)
    end
    expected_msg = "0123456789"
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test occursin(expected_msg, json.message)

    @test json.attrs.x.part1 == 10
    @test json.attrs.x.part2 == 20
    @test json.attrs.y.part3 == "very long "
    @test json.attrs.y.part4 == 40
    @test occursin("part3 = \"very long string\"", json.message)
end

@testset "Max attribute character count infinite recursion dict edition (JSONLogger only)" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            max_attr_char_count=200,
            attr_char_limit=10,
            transaction_id="100",
        ),
    ) do
        d = Dict(9876543210 => 8765432109, "7654321098" => "6543210987")
        d[3] = d
        @info "0123456789" my_ill_behaved_dict = d
    end
    expected_msg = "0123456789"
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test occursin(expected_msg, json.message)

    @test json.attrs.my_ill_beh[9876543210] == 8765432109
    @test json.attrs.my_ill_beh["7654321098"] == "6543210987"

    # the main point of this test is that it should not stack overflow. the logger does not
    # do cycle detection, so the attributes will be full of garbage, but the character limit
    # will keep it from recursing forever. it's not ideal, but it prevents us from exploding
    # without overly complicating things.
end

@testset "SAS token scrubbing (JSONLogger only)" begin
    log_buffer = IOBuffer()
    sas_token = "sv=2015-07-08sr=b&sig=39Up9.IzHkxhUIhFEJEH9594DJxe7w6cIRCgOV6ICGS0%3D\
        &se=2016-10-18T21%3A51%3A37Z&sp=rcm"
    sas_token_scrubbed = "sv=2015-07-08sr=b&*********************&\
        se=2016-10-18T21%3A51%3A37Z&sp=rcm"

    # Rel snippet containing a SAS token.
    message = """def config[:integration, :credentials, :azure_sas_token]= \"$sas_token\""""
    Logging.with_logger(JSONLogger(stream=log_buffer)) do
        @info message
    end
    generated_log_message = String(take!(log_buffer))
    @test !occursin(sas_token, generated_log_message)
    @test occursin(sas_token_scrubbed, generated_log_message)

    # Rel snippet containing two SAS tokens.
    message2 = """def config[:integration, :credentials, :azure_sas_token]= \"$sas_token\"
        def config2[:integration, :credentials, :azure_sas_token]= \"$sas_token\"
    """
    log_buffer = IOBuffer()
    Logging.with_logger(JSONLogger(stream=log_buffer)) do
        @info message2
    end
    generated_log_message2 = String(take!(log_buffer))
    @test !occursin(sas_token, generated_log_message2)
    @test occursin(sas_token_scrubbed, generated_log_message2)

    # Rel snippet containing a SAS token with the signature at the end.
    sas_token2 = "sv=2015-07-08sr=b&se=2016-10-18T21%3A51%3A37Z&sp=rcm\
        &sig=39Up9.IzHkxhUIhFEJEH9594DJxe7w6cIRCgOV6ICGS0%3D"
    sas_token_scrubbed2 = "sv=2015-07-08sr=b&se=2016-10-18T21%3A51%3A37Z&sp=rcm\
        &*********************"
    message3 = """def config[:integration, :credentials, :azure_sas_token]= \"$sas_token2\"
    """
    log_buffer = IOBuffer()
    Logging.with_logger(JSONLogger(stream=log_buffer)) do
        @info message3
    end
    generated_log_message3 = String(take!(log_buffer))
    @test !occursin(sas_token2, generated_log_message3)
    @test occursin(sas_token_scrubbed2, generated_log_message3)
end


@testset "Account and engine name attributes" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        JSONLogger(
            stream=log_buffer,
            account_name="acc_name",
            engine_name="eng_name"
        ),
    ) do
        @info "0123456789"
    end
    expected_msg = "0123456789"
    generated_log_message = String(take!(log_buffer))
    json = JSON3.read(generated_log_message)
    @test occursin(expected_msg, json.message)
    # the account and engine name should appear in the tags
    @test json["rai.account_name"] == "acc_name"
    @test json["rai.engine_name"] == "eng_name"

    log_buffer = IOBuffer()
    Logging.with_logger(
        LocalLogger(
            stream=log_buffer,
            account_name="acc_name",
            engine_name="eng_name"
        ),
    ) do
        @info "0123456789"
    end
    expected_msg = "0123456789"
    generated_log_message = String(take!(log_buffer))
    @test occursin(expected_msg, generated_log_message)
    @show generated_log_message
    # the account and engine name should appear in the log message
    @test occursin(" (account_name: acc_name", generated_log_message)
    @test occursin(" (engine_name: eng_name", generated_log_message)
end

@testset "LocalLogger handing message with all attributes" begin
    log_buffer = IOBuffer()
    Logging.with_logger(
        LocalLogger(
            stream=log_buffer,
            request_id="123",
            transaction_id="123-123-123-123",
            trace_id="1234567890",
            database_name="dat_name",
            account_name="acc_name",
            engine_name="eng_name"
        ),
    ) do
        @info "0123456789"
    end
    generated_log_message = String(take!(log_buffer))
    expected_elements = [
        "(request_id: 123)", "(transaction_id: 123-123-123-123)",
        "(trace_id: 1234567890)", "(database_name: dat_name)",
        "(account_name: acc_name)", "(engine_name: eng_name)\n"
    ]
    expected_string = join(expected_elements, " ")
    @test occursin(expected_string, generated_log_message)
end

end # testitem
