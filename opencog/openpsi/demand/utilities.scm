; Copyright (C) 2015 OpenCog Foundation

(use-modules (ice-9 optargs)) ; for optional arguments in define-psi-demand
(use-modules (rnrs sorting)) ; needed for sorting demands by their values.
(use-modules (opencog exec) (opencog rule-engine))

(load-from-path "openpsi/utilities.scm")

; --------------------------------------------------------------
(define-public (psi-demand-pattern)
"
  Returns an alist used to define the psi demand pattern. The key strings are,
  - 'var': its value is a list containing the VariableNodes and their type
           restrictions.
  - 'pat': its value is a DefinedPredicateNode that is associated with the
           demand pattern.
"
    (define z-alist (acons "var" (list
        (TypedVariableLink
            (VariableNode "Demand")
            (TypeNode "ConceptNode")
        )
        (TypedVariableLink
            (VariableNode "min_acceptable_value")
            (TypeNode "NumberNode")
        )
        (TypedVariableLink
            (VariableNode "max_acceptable_value")
            (TypeNode "NumberNode")
        ))
        '()))
    (define dpn (DefinedPredicateNode
        (string-append (psi-prefix-str) "demand-pattern")))

    (DefineLink
        dpn
        (PresentLink
            (InheritanceLink
                ; the strength of the stv is the demand value
                (VariableNode "Demand")
                (ConceptNode (string-append (psi-prefix-str) "Demand")))
            ; This is equivalent to an in-born drive/goal. When
            ; the value goes out of range then urge occurs
            (EvaluationLink
                (PredicateNode (string-append (psi-prefix-str) "default_value"))
                (ListLink
                    (VariableNode "Demand")
                    (VariableNode "default_value")))))
    (acons "pat" dpn z-alist)
)

; --------------------------------------------------------------
(define-public (psi-get-demands)
"
  Returns a list containing the ConceptNode that carry the demand-value. The
  strength of their stv is the demand value.
"
    (psi-clean-demand-gets (cog-execute!
        (GetLink
            (VariableList (assoc-ref (psi-demand-pattern) "var"))
            (assoc-ref (psi-demand-pattern) "pat"))))
)

; --------------------------------------------------------------
(define-public (define-psi-demand  demand-name default-value default-action)
"
  Define an OpenPsi demand, that will have a default behavior defined by the
  the action passed.

  demand-name:
  - The name of the demand that is created.

  default-value:
  - The initial demand-value. This is the strength of the demand's
    ConceptNode stv. The confidence of the stv is always 1.

  default-action:
  - The default action that modifies the demand-value.
"

    (let* ((demand-str (string-append (psi-prefix-str) demand-name))
           (demand-node (ConceptNode demand-str (stv default-value 1))))
        (begin
            (InheritanceLink
                demand-node
                (ConceptNode (string-append (psi-prefix-str) "Demand"))
            )

            ; This is the goal of the demand
            (EvaluationLink
                (PredicateNode (string-append (psi-prefix-str) "default_value"))
                (ListLink
                    demand-node
                    (NumberNode default-value)
                )
            )

            ; This specifies the default action that each psi-demand must have.
            (EvaluationLink
                (PredicateNode (string-append (psi-prefix-str) "acts-on"))
                (ListLink
                    (GroundedSchemaNode "scm: psi-demand-updater")
                    demand-node
                )
            )

            ; Add the default action. URE uses BindLinks for rules so action
            (define-psi-action
                (assoc-ref (psi-demand-pattern) "var")
                (assoc-ref (psi-demand-pattern) "pat")
                default-action
                demand-name
                "Default")
            ; Each demand is also a rulebase
            (ure-define-rbs demand-node 1)
        )
    )
)

; --------------------------------------------------------------
(define (psi-demand? atom)
"
  Checks whether an atom is the ConceptNode that satisfies the pattern used
  to define an OpenPsi demand. Returns True-TruthValue `(stv 1 1)` if it is
  and False-TruthValue `(stv 0 1)` if it isn't.

  atom:
  - The atom that is being checked to see if it is the Node that represents
    a demand type.
"
    (define demand-names (map cog-name (psi-get-demands)))
    (if (and (member (cog-name atom) demand-names)
             (equal? (cog-type atom) 'ConceptNode))
        (stv 1 1)
        (stv 0 1)
    )
)

; --------------------------------------------------------------
(define (psi-lowest-demand? atom)
"
  Returns #t if the atom passed is a demand that has the lowest demand-value.

  atom:
  - The atom that is being checked to see if it is the Node that represents
    a demand type, with a lowest demand-value.
"
    ; check if atom is a demand-node
    (if (equal? (stv 0 1) (psi-demand? atom))
        (error "Expected argument to be a demand-node, got: " atom))

    (let ((atom-strength (tv-mean (cog-tv atom)))
          (lowest-demand-value (car (list-sort < (delete-duplicates
              (map (lambda (x) (tv-mean (cog-tv x))) (psi-get-demands))))))
         )
         (if (<= atom-strength lowest-demand-value)
            (stv 1 1)
            (stv 0 1)
         )
    )
)

; --------------------------------------------------------------
(define (psi-action-types)
"
  Returns a list of the default action types, that are used to describe how
  an action affects the demands it is associated with. The availabe action
  types are,

  Increase: increases the demand-value.
  Decrease: decreases the demand-value.
  Default: depends on the default-action associated with it. And is used
           to define how the demand-value should change independent of context.

"
    ; NOTE: Update psi-update-asp and psi-get-all-actions
    ; when adding other effect types.
    (list "Increase" "Decrease" "Default")
)

; --------------------------------------------------------------
(define (define-psi-action vars context action demand-name effect-type)
"
  It associates an action and context in which the action has to be taken
  to an OpenPsi-demand. It returns a node that defines/aliases the BindLink
  structured as,
    (BindLink
        (VariableList (vars))
        (AndLink
            (context)
            (clauses required for linking with the demand named demand-name))
        (action))

  A single action-rule could only have a either of the effect-types, thus
  changing the effect-type will not have any effect if the action-rule has
  already been defined in the atomspace with a different effect-type.

  vars:
    - A list containing the VariableNodes, and their type restrictions, that
      are part of the context. If there is no type restrictions then pass empty
      list.

  context:
    - A list containing the terms/clauses that should be met for this action
      to be taken. Be careful on how you use Variable naming in the context

  action:
    - The Implicand of the rule. It should be an atom that uses the groundings
      of the context to do something.

  demand-name:
    - The name of the demand that is affected by the execution of the function
      associated with the action.
    - Shouldn't include `psi-prefix-str`
    - It is case sensetive, that is, a demand named `Energy` is not equal
      to a demand named `energy`. If you pass a name of a not defined node,
      since it's unrecognized it won't be run, eventhough a BindLink is
      returned.

  effect-type:
    - A string that describes the effect the particualr action would have on
      the demand value. See `(psi-action-types)` for available options.

"
    (define rule-name-prefix
        (string-append (psi-prefix-str) demand-name "-rule-"))
    (define rule-name (string-append rule-name-prefix (random-string 5)))
    (define (demand-node)
        (ConceptNode (string-append (psi-prefix-str) demand-name)))

    (define (rule)
        ; Is function to avoid  insertion into the atomspace if argument check
        ; fails.
        (BindLink
            ; An empty VariableList prevents matchs.
            (if (equal? '() vars)
                '()
                (VariableList vars)
            )
            (AndLink
                context
                (EvaluationLink ; Act only if their is such a demand.
                    (GroundedPredicateNode "scm: psi-demand?")
                    (ListLink (demand-node))))
            action))

    (define (create-psi-action)
        (let ((alias (ure-add-rule demand-node rule-name (rule))))
            (InheritanceLink
                alias
                (ConceptNode "opencog: action"))

            (EvaluationLink
                (PredicateNode (string-append (psi-prefix-str) effect-type))
                (ListLink
                    (Node rule-name)
                    (demand-node)))
            alias
        ))

    ; Check arguments
    (if (not (list? vars))
        (error "Expected first argument to be a list, got: " vars))
    (if (not (list? context))
        (error "Expected second argument to be a list, got: " context))
    (if (not (cog-atom? action))
        (error "Expected third argument to be an atom, got: " action))
    (if (not (member effect-type (psi-action-types)))
        (error (string-append "Expected fourth argument to be one of the "
            "action types listed when running `(psi-action-types)`, got: ")
            effect-type))

    ; Check if the rule has already been defined as a member of
    ; TODO: this needs improvement not exaustive enough, it isn't considering
    ;       other differentiating graphs.
    (let ((node (cog-chase-link 'DefineLink 'Node (rule))))
        (cond ((and (= 1 (length node))
                    (string-prefix? rule-name-prefix (cog-name (car node))))
                     node)
              ((= 0 (length node)) (create-psi-action))
              (else (error "The rule has been defined multiple times"))
        )
    )
)

; --------------------------------------------------------------
(define (psi-get-actions demand-node effect-type)
"
  Returns a list containing the 'Node atom-type atoms that name the action-rules
  for the given demand-node.

  demand-node:
    - A ConceptNode that represents a demand.

  effect-type:
    - A string that describes the effect the particualr action would have on
      the demand value. See `(psi-action-types)` for available options.
"
    ; Check arguments
    (if (not (member effect-type (psi-action-types)))
        (error (string-append "Expected fourth argument to be one of the "
            "action types listed when running `(psi-action-types)`, got: ")
            effect-type))

    (cog-outgoing-set (cog-execute!
        (GetLink
             (TypedVariableLink
                 (VariableNode "x")
                 (TypeNode "Node"))
             (AndLink
                 (EvaluationLink
                     (PredicateNode
                         (string-append (psi-prefix-str) effect-type))
                     (ListLink
                        (VariableNode "x")
                        demand-node))
                 (InheritanceLink
                     (VariableNode "x")
                     (ConceptNode "opencog: action"))))
    ))
)

; --------------------------------------------------------------
(define (psi-get-all-actions demand-node)
"
  Returns a list containing the 'Node atom-type atoms that name the action-rules
  for the given demand-node.

  demand-node:
    - A ConceptNode that represents a demand.
"
    (append
        (psi-get-actions demand-node "Increase")
        (psi-get-actions demand-node "Decrease")
    )
)

; --------------------------------------------------------------
(define (psi-select-actions demand-node gpn)
"
  Select the actions that should be added to the active-schema-pool depending
  on the present goal, by using the plan choosen by the GroundedPredicateNode.

  demand-node:
    - A ConceptNode that represents a demand

  gpn:
   - GroundedPredicateNode that refers to a function that checks the actions
     for constraints.
"
    ;TODO: I think the planner is kind of a behavior tree genrator (assuming
    ; there is no change of a preset plan) .URE's random selection policy
    ; isn't being used now thus each plan is in effect a single action choosen,
    ; this has to be improved but is good for starters.

    ; Check arguments
    (if (not (equal? (cog-type gpn) 'GroundedPredicateNode))
        (error "Expected DefinedPredicateNode got: " gpn))

    (cog-outgoing-set (cog-execute!
        (GetLink
             (TypedVariableLink
                 (VariableNode "x")
                 (TypeNode "Node"))
             (AndLink
                 (EvaluationLink
                     gpn
                     (ListLink  (VariableNode "x")))
                 (MemberLink
                     (VariableNode "x")
                     demand-node)
                 (InheritanceLink
                     (VariableNode "x")
                     (ConceptNode "opencog: action"))))
    ))
)
