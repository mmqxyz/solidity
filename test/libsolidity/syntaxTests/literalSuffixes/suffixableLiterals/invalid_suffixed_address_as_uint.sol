function suffix(uint value) pure suffix returns (uint) { return value; }

contract C {
    uint x = 0x1234567890123456789012345678901234567890 suffix;
}
// ----
// TypeError 8838: (100-149): The literal cannot be converted to the type accepted by the suffix function.
