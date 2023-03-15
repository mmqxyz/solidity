function suffix(uint x) pure suffix returns (uint) { return x; }

contract C {
    uint x = 10e1000 suffix;
    uint y = 999999999999999999999999999999999999999999999999999999999999999999999999999999 suffix;
}
// ----
// TypeError 5503: (92-106): The literal is out of range of any supported integer type.
// TypeError 8838: (92-106): The number is out of range of type uint256 accepted by the suffix function.
// TypeError 5503: (121-206): The literal is out of range of any supported integer type.
// TypeError 8838: (121-206): The number is out of range of type uint256 accepted by the suffix function.
