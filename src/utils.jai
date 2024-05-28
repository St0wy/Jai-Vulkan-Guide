#scope_module

// Return the length of s, a C-style zero-terminated string.
// If you pass in a pointer that is not zero-terminated, BAD things will happen!
strlen :: (s: *u8) -> s64 
{  
    count: s64 = 0;

    while << s {
        count += 1;
        s += 1;
    }

    return count;
}

strcmp :: (s1: *u8, s2: *u8) -> s32
{
	while (<<s1 != #char "\0" && (<<s1 == <<s2)) 
	{
		s1 += 1; 
		s2 += 1;
	}
    return (<<s1 - <<s2);
}

offset_of :: ($T: Type, ident: Code) -> s64 #expand 
{
    t: T = ---;
    return cast(*void) (*t.#insert ident) - cast(*void) *t;
}
