require 'utilrb/test'
require 'flexmock/minitest'
require 'tempfile'

require 'utilrb/kernel/immediate_p'

class TC_Kernel < Minitest::Test
    def test_immediate_p
        assert Kernel.immediate?(0)
    end
end

