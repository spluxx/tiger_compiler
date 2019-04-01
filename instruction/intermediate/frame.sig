signature FRAME = 
sig 
  type frame
  type access
	type register = string

	val registers: register list

  val newFrame : {name: Temp.label, formals: bool list} -> frame
  val name : frame -> Temp.label
  val formals : frame -> access list
  val allocLocal : frame -> bool -> access

  val exp : access -> Tree.exp -> Tree.exp
  val procEntryExit1 : frame * Tree.stm -> Tree.stm
	val procEntryExit2: frame * Assem.instr list -> Assem.instr list
	val procEntryExit3 : frame * Assem.instr list -> 
				{prolog: string, body: Assem.instr list, epilog: string}
  val externalCall: string * Tree.exp list -> Tree.exp

  val wordSize : int

  val FP : Temp.temp
  val RV : Temp.temp

  datatype frag = PROC of {body: Tree.stm, frame: frame}
                | STRING of Temp.label * string

  val accessToStr: access -> string
  val printFrag: TextIO.outstream * frag -> unit

  val string : Tree.label * string -> string

end
